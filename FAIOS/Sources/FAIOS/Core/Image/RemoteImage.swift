import Foundation
import SwiftUI
import UIKit
import FAPages

/// 图片加载器。
///
/// 为什么不用 `AsyncImage`：它走 `URLSession.shared`，UA 和 cookie 都不受我们控制。
/// FA 的图片走 Cloudflare，而我们自己的会话带着身份、挑战检测与限流 —— 图片也必须走同一条路。
/// 顺带还能做三件 `AsyncImage` 做不到的事：内存缓存、去重（同一张图只下一次）、失败可读。
actor FAImageCache {

    static let shared = FAImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024   // 2GB 设备上给图片留 64MB
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        if let running = inFlight[url] {
            return try await running.value
        }

        let task = Task<UIImage, Error> { [cache] in
            let data = try await FAHTTP.shared.fetchData(url)
            guard let image = UIImage(data: data) else {
                throw FAImageError.undecodable(data.count)
            }
            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        }
        inFlight[url] = task

        defer { inFlight[url] = nil }
        return try await task.value
    }
}

enum FAImageError: Error, CustomStringConvertible {
    case undecodable(Int)
    var description: String {
        switch self {
        case .undecodable(let n): return "undecodable image (\(n) bytes)"
        }
    }
}

/// 带缓存、带失败的图片视图。失败时把原因显示出来 —— 在真机上没有控制台，
/// 屏幕上的一行小字就是最好的调试器。
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
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
            image = nil
            debugText = nil
            do {
                let loaded = try await FAImageCache.shared.image(for: url)
                image = loaded
                onLoad?(loaded.size)
            } catch {
                debugText = String(describing: error)
            }
        }
    }
}
