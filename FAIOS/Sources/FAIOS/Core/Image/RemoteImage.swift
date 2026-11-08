import Foundation
import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import FAPages

/// 图片加载器（两级缓存 + 降采样）。
///
/// 为什么不用 `AsyncImage`：它走 `URLSession.shared`，UA 和 cookie 都不受我们控制。
/// FA 的图片走 Cloudflare，而我们自己的会话带着身份、挑战检测与限流 —— 图片也必须走同一条路。
///
/// 为什么不用 `UIImage(data:)`：它按**原始像素**解码。一张 2474×1489 的稿子在 108pt 的格子里
/// 只占 300×180 点，却要吃掉 14.7MB 内存（2474×1489×4）—— 网格里滚两屏就会收内存警告。
/// 这里用 ImageIO 的 thumbnail API **在解码阶段就降到目标尺寸**，同样的图只占 ~0.7MB。
actor FAImageCache {

    static let shared = FAImageCache()

    struct Stats {
        var memoryHits = 0
        var diskHits = 0
        var networkLoads = 0
        var failures = 0
        var decodeMilliseconds = 0.0
        var diskBytes: Int64 = 0
        var diskFiles = 0
        var diskPath = ""
        var writeFailures = 0

        var totalRequests: Int { memoryHits + diskHits + networkLoads + failures }

        /// 命中率：内存算满命中，磁盘算半命中（省了网络，仍要解码）
        var hitRate: Double {
            guard totalRequests > 0 else { return 0 }
            return Double(memoryHits) / Double(totalRequests)
        }

        var summary: String {
            guard totalRequests > 0 else { return "还没有加载过图片" }
            let ms = decodeMilliseconds / Double(max(networkLoads + diskHits, 1))
            let rate = (memoryHits + diskHits) > 0
                ? Double(memoryHits + diskHits) / Double(totalRequests) * 100
                : 0
            return String(format: "内存 %d · 磁盘 %d · 网络 %d · 失败 %d｜省网络 %.0f%%｜均解码 %.0fms｜磁盘 %@（%@）%@",
                          memoryHits, diskHits, networkLoads, failures,
                          rate, ms, Self.bytes(diskBytes), Self.short(diskPath),
                          writeFailures > 0 ? "｜写盘失败 \(writeFailures)" : "")
        }

        /// 路径太长，只留最后两级，够看出来落在容器里还是 /var/tmp
        static func short(_ path: String) -> String {
            guard !path.isEmpty else { return "?" }
            let parts = path.split(separator: "/").suffix(2).joined(separator: "/")
            return parts.isEmpty ? path : "/" + parts
        }

        static func bytes(_ value: Int64) -> String {
            let mb = Double(value) / (1024 * 1024)
            if mb >= 1 { return String(format: "%.1fMB", mb) }
            return String(format: "%.0fKB", Double(value) / 1024)
        }
    }

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private var stats = Stats()

    private let diskDirectory: URL
    private let diskLimit: Int64 = 320 * 1024 * 1024   // 320MB 上限，够存几千张缩略图
    private var writesSincePrune = 0

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 96 * 1024 * 1024

        // 容器目录可能根本不可写（adhoc 签名的 .app 装到 /var/jb 时，沙箱不给数据容器权限，
        // 实测往 Documents/Caches 写会拿到 NSCocoaErrorDomain 513）—— 所以挨个试探，
        // 第一个真能写进去的才用。真机上的读数会显示最终落到了哪。
        diskDirectory = Self.makeWritableDirectory()
        stats.diskPath = diskDirectory.path
    }

    private static func makeWritableDirectory() -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches.appendingPathComponent("FAImages", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAImages", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/var/tmp/faios-images", isDirectory: true))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("faios-images", isDirectory: true))

        for candidate in candidates {
            try? fm.createDirectory(at: candidate, withIntermediateDirectories: true)
            let probe = candidate.appendingPathComponent("probe")
            do {
                try Data("x".utf8).write(to: probe)
                try? fm.removeItem(at: probe)
                return candidate
            } catch {
                continue
            }
        }
        // 全都写不进去：退化成纯内存缓存（功能不受影响，只是重启后要重新下）
        return URL(fileURLWithPath: NSTemporaryDirectory())
    }

    // MARK: - 对外

    /// - Parameters:
    ///   - maxPixelSize: 目标长边像素。传 nil 表示按原始尺寸（原图查看器用）。
    func image(for url: URL, maxPixelSize: Int?) async throws -> UIImage {
        let key = Self.key(url: url, maxPixelSize: maxPixelSize)

        if let cached = memory.object(forKey: key as NSString) {
            stats.memoryHits += 1
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw FAImageError.cancelled }
            return try await self.load(url: url, key: key, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// 只查内存，不触发下载 —— 给「先显示旧的、再刷新」用
    func memoryImage(for url: URL, maxPixelSize: Int?) -> UIImage? {
        memory.object(forKey: Self.key(url: url, maxPixelSize: maxPixelSize) as NSString)
    }

    func snapshot() -> Stats {
        var copy = stats
        let (bytes, files) = Self.directorySize(diskDirectory)
        copy.diskBytes = bytes
        copy.diskFiles = files
        return copy
    }

    func clear() async {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        stats = Stats()
    }

    // MARK: - 装载

    private func load(url: URL, key: String, maxPixelSize: Int?) async throws -> UIImage {
        // 磁盘：先看有没有
        let file = diskDirectory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
           let image = Self.decode(data, maxPixelSize: maxPixelSize) {
            stats.diskHits += 1
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            return image
        }

        // 网络
        let data: Data
        do {
            data = try await FAHTTP.shared.fetchData(url)
        } catch {
            stats.failures += 1
            throw error
        }

        stats.networkLoads += 1
        let started = Date()
        guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else {
            stats.failures += 1
            throw FAImageError.undecodable(data.count)
        }
        stats.decodeMilliseconds += Date().timeIntervalSince(started) * 1000

        memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))

        // 写盘（原样存字节，解码尺寸由 key 决定，所以一张原图只下一次）
        do {
            try data.write(to: file, options: .atomic)
            writesSincePrune += 1
            if writesSincePrune % 16 == 0 { pruneDiskIfNeeded() }
        } catch {
            // 写不进去不致命（下次还得重新下），但要知道发生过
            stats.writeFailures += 1
        }
        return image
    }

    // MARK: - 工具

    private static func key(url: URL, maxPixelSize: Int?) -> String {
        let raw = "\(url.absoluteString)#\(maxPixelSize.map(String.init) ?? "full")"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// ImageIO 降采样：解码阶段就按目标尺寸出图，内存占用跟着目标尺寸走
    private static func decode(_ data: Data, maxPixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // 尺寸未知或要求原图：直接解
        guard let maxPixelSize else {
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: cg)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,       // 在后台线程就解完，别留给主线程
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // 有的格式（少数 APNG/动图首帧）缩略图 API 会失败，退回普通解码
            guard let fallback = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: fallback)
        }
        return UIImage(cgImage: cg)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    private static func directorySize(_ directory: URL) -> (Int64, Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return (0, 0) }

        var total: Int64 = 0
        for item in items {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return (total, items.count)
    }

    /// 超上限就按修改时间删最旧的，删到 80% 为止（别每次都删，磁盘 IO 也要钱）
    private func pruneDiskIfNeeded() {
        let (bytes, _) = Self.directorySize(diskDirectory)
        guard bytes > diskLimit else { return }

        let target = Int64(Double(diskLimit) * 0.8)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }

        var current = bytes
        for item in sorted where current > target {
            let size = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: item)) != nil {
                current -= size
            }
        }
    }
}

enum FAImageError: Error, CustomStringConvertible {
    case undecodable(Int)
    case cancelled

    var description: String {
        switch self {
        case .undecodable(let n): return "undecodable image (\(n) bytes)"
        case .cancelled: return "cancelled"
        }
    }
}

/// 带缓存、带降采样、带失败原因的图片视图。
/// 失败时把原因显示出来 —— 在真机上没有控制台，屏幕上的一行小字就是最好的调试器。
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// 目标长边像素。传 nil 表示原图（查看器用）。
    /// 缩略图/头像一定要传 —— 否则一屏 12 张稿子会按原始分辨率解码成几百 MB。
    var maxPixelSize: Int? = nil
    /// 加载成功后回调真实像素尺寸，调用方可以据此定宽高比（避免布局跳动）
    var onLoad: ((CGSize) -> Void)?

    @State private var image: UIImage?
    @State private var debugText: String?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let debugText {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                    Text(debugText)
                        .font(.system(size: 7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .foregroundColor(.secondary)
                .padding(3)
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .task(id: url) {
            guard let url else {
                debugText = "no url"
                return
            }
            // 内存里有时先直接上屏，别闪一下转圈
            if let ready = await FAImageCache.shared.memoryImage(for: url, maxPixelSize: maxPixelSize) {
                image = ready
                onLoad?(ready.size)
                return
            }
            image = nil
            debugText = nil
            do {
                let loaded = try await FAImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                image = loaded
                onLoad?(loaded.size)
            } catch is CancellationError {
                // 划走的格子，什么都不用做
            } catch {
                debugText = String(describing: error)
            }
        }
    }
}

/// 目标像素的常用档位，集中放一处，免得各处随手写数字
enum FAImageSize {
    /// 网格缩略图：格子约 110pt，@3x = 330，留点余量
    static let thumbnail = 420
    /// 详情页 hero：整屏宽
    static var hero: Int {
        Int(UIScreen.main.bounds.width * UIScreen.main.scale)
    }
    /// 头像（30–64pt）
    static let avatar = 160
}
