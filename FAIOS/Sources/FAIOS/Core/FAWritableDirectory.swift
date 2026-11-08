import Foundation

/// 找一个真正能写的目录。
///
/// 这台机器上的 App 是手动 `cp -R` 装的，沙箱容器没初始化 ——
/// `Documents`、`Library/Caches`、容器的 `tmp` 全都不可写（`NSCocoaErrorDomain 513`），
/// 唯一稳定可写的是 `/var/tmp`。正常签名安装时 `Documents` 可写，两边都成立。
///
/// 探测方式不是「目录存在吗」，而是**真的写一个文件再删掉** ——
/// 目录存在但沙箱拒绝写入，正是这里的常态。
enum FAWritableDirectory {

    private static var cache: [String: URL] = [:]

    static func directory(_ subfolder: String) -> URL? {
        if let cached = cache[subfolder] { return cached }

        let bases: [URL?] = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            URL(fileURLWithPath: "/var/tmp", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ]

        for base in bases {
            guard let base else { continue }
            let target = base.appendingPathComponent("FAIOS", isDirectory: true)
                .appendingPathComponent(subfolder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let probe = target.appendingPathComponent(".probe")
                try Data("ok".utf8).write(to: probe, options: .atomic)
                try? FileManager.default.removeItem(at: probe)
                cache[subfolder] = target
                return target
            } catch {
                continue
            }
        }
        return nil
    }

    /// 「/var/tmp/FAIOS/audio」→「audio」这种短标签，给调试行显示用
    static func shortLabel(_ url: URL) -> String {
        let parts = url.pathComponents
        guard parts.count >= 2 else { return url.path }
        return parts.suffix(2).joined(separator: "/")
    }
}
