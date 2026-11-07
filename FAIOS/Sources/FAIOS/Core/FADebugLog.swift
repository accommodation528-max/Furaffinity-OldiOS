import Foundation

/// 真机调试用的小日志。
///
/// iPhone 上没有控制台，`log` 命令在 rootless 越狱环境里也没有，Xcode 更不存在。
/// 所以：关键事件写进 App 沙盒的 `Documents/debug.log`，
/// 再用 SSH 从电脑上 `cat` 出来 —— root 能进 App 容器。
///
///     ssh root@<ip> 'ls -t /var/mobile/Containers/Data/Application/*/Documents/debug.log | head -1 | xargs tail -40'
enum FADebugLog {

    private static let queue = DispatchQueue(label: "faios.debuglog")

    private static let fileURL: URL? = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("debug.log")

    /// 追加一行（自动加时间戳）
    static func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            guard let url = fileURL else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
