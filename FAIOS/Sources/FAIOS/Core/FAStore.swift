import Foundation

/// 本地设置的落盘层。
///
/// 为什么不用 `UserDefaults`：这台机器上的 App 是「手动拷贝 .app」装的，
/// 沙箱容器没有正常初始化 —— `Documents`、`Library/Caches`、`Library/Preferences`
/// 全都不可写（`NSCocoaErrorDomain 513`），`UserDefaults` 写完静默丢弃，
/// 于是**所有设置一关 App 就没了**（字号、分级模式、搜索历史、阅读进度）。
///
/// 所以这里自己找一个真正能写的地方存 JSON：
/// Documents → Library/Caches → 容器 tmp → `/var/tmp` → 家目录。
/// 越狱设备上 `/var/tmp` 通常可写，正常签名安装时 Documents 可写，两边都成立。
enum FAStore {

    /// 单例状态（只在主线程读写，设置项都是 UI 级数据）
    @MainActor
    private static var values: [String: Any] = [:]

    @MainActor
    private static var loaded = false

    // MARK: - 读写

    @MainActor
    static func string(_ key: String, default fallback: String? = nil) -> String? {
        ensureLoaded()
        return values[key] as? String ?? fallback
    }

    @MainActor
    static func int(_ key: String, default fallback: Int = 0) -> Int {
        ensureLoaded()
        if let value = values[key] as? Int { return value }
        if let value = values[key] as? Double { return Int(value) }
        return fallback
    }

    @MainActor
    static func double(_ key: String, default fallback: Double) -> Double {
        ensureLoaded()
        if let value = values[key] as? Double { return value }
        if let value = values[key] as? Int { return Double(value) }
        return fallback
    }

    @MainActor
    static func set(_ value: Any?, for key: String) {
        ensureLoaded()
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        schedulePersist()
    }

    @MainActor
    static func remove(_ key: String) {
        set(nil, for: key)
    }

    // MARK: - 落盘

    private static var persistScheduled = false

    @MainActor
    private static func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        // 合并短时间内的多次写入（字号连点、滚动记进度）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            persistScheduled = false
            persistNow()
        }
    }

    @MainActor
    static func persistNow() {
        guard let url = fileURL() else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = String(describing: error)
        }
    }

    /// 最近一次写盘错误（屏幕上给调试行看）
    @MainActor
    static private(set) var lastWriteError: String?

    /// 设置文件的实际路径（屏幕调试行展示）
    @MainActor
    static private(set) var filePath: String?

    // MARK: - 目录发现

    @MainActor
    private static var resolvedDirectory: URL?

    @MainActor
    private static func directory() -> URL? {
        if let resolvedDirectory, FileManager.default.fileExists(atPath: resolvedDirectory.path) {
            return resolvedDirectory
        }
        let candidates: [(String, URL?)] = [
            ("Documents", FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("Caches", FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first),
            ("tmp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)),
            ("var-tmp", URL(fileURLWithPath: "/var/tmp", isDirectory: true)),
            ("home", URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        ]

        for (_, base) in candidates {
            guard let base else { continue }
            let target = base.appendingPathComponent("FAIOS", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                // 探测写权限：能写进去才算数（目录存在但沙箱拒绝写入是这台机器的常态）
                let probe = target.appendingPathComponent(".probe")
                try Data("ok".utf8).write(to: probe, options: .atomic)
                try? FileManager.default.removeItem(at: probe)
                resolvedDirectory = target
                return target
            } catch {
                continue
            }
        }
        return nil
    }

    @MainActor
    private static func fileURL() -> URL? {
        guard let directory = directory() else { return nil }
        let url = directory.appendingPathComponent("settings.json")
        filePath = url.path
        return url
    }

    // MARK: - 载入

    @MainActor
    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        values = object
    }
}
