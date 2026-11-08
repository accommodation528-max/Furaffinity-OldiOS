import Foundation
import Combine
import UIKit
import FAPages

/// 批量下载：把列表里已经加载的投稿图存到本地，供「文件」App 取用。
///
/// 两个限制必须说清（都来自 FA 的页面结构，不是我们偷懒）：
/// - 列表页只给缩略图地址，原图地址只有详情页才有。所以这里下的是 @600 档（`t.furaffinity.net`），
///   想要原图得走详情页的单张下载。
/// - FA 有限速（页面 3 并发 / 350ms，资源 6 并发 / 80ms），这里串行下载 + 复用图片缓存车道，
///   一次几十张会花几十秒——进度条是必需的，不是装饰。
@MainActor
final class BatchDownloader: ObservableObject {

    static let shared = BatchDownloader()

    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int, current: String)
        case finished(saved: Int, failed: Int, folder: String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// 下载目标目录（不保证可写，失败时返回 nil）
    static func directory() -> URL? {
        FAWritableDirectory.directory("downloads")
    }

    /// - Parameter submissions: 要下载的投稿（用缩略图地址换成更大一档）
    /// - Parameter reuseExisting: 同名文件已存在就跳过（重复点下载不会重复写盘）
    func download(_ submissions: [FASubmission], reuseExisting: Bool = true) {
        guard !isRunning, !submissions.isEmpty else { return }
        guard let folder = Self.directory() else {
            phase = .finished(saved: 0, failed: submissions.count, folder: "（找不到可写目录）")
            return
        }

        phase = .running(done: 0, total: submissions.count, current: "")
        task = Task { [weak self] in
            guard let self else { return }
            var saved = 0
            var failed = 0
            for (index, submission) in submissions.enumerated() {
                if Task.isCancelled { break }
                let url = FAURLs.thumbnailSized(submission.thumbnailURL, pixels: 600)
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                let target = folder.appendingPathComponent("\(submission.id).\(ext)")

                self.phase = .running(done: index, total: submissions.count, current: submission.title)

                if reuseExisting,
                   let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int,
                   size > 1024 {
                    saved += 1
                    continue
                }

                do {
                    let data = try await FAFetch.data(url)
                    // 1KB 以下基本是错误页或空响应，宁可算失败也不留个坏文件在目录里
                    guard data.count > 1024 else { throw FAHTTP.FAHTTPError.http(204) }
                    try data.write(to: target, options: .atomic)
                    saved += 1
                } catch {
                    failed += 1
                    FADiag.record("batch download \(submission.id) 失败：\(FAErrorMessage.describe(error))")
                }
            }
            self.phase = .finished(saved: saved, failed: failed, folder: Self.shortPath(folder))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismiss() {
        phase = .idle
    }

    private static func shortPath(_ url: URL) -> String {
        let components = url.pathComponents
        let tail = components.suffix(3).joined(separator: "/")
        return tail.isEmpty ? url.path : "…/" + tail
    }
}
