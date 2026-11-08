import Foundation
import FAPages

/// FA 的两个登录 cookie（`a` = 会话，`b` = 另一份绑定值）以及 Cloudflare 的 `cf_clearance`。
///
/// 存储策略（两级，按可用性降级）：
/// 1. **Keychain** —— 首选。加密、不进 iCloud（`…ThisDeviceOnly`）
/// 2. **文件兜底** —— ad-hoc 签名的二进制没有 `application-identifier` entitlement 时
///    Keychain 会返回 `-34018`（实测就是这种情况），此时退到 App 容器里的文件，
///    并打上 `.completeFileProtection`（锁屏即加密）。
///
/// 不论哪一级，都只在**本机 App 沙盒**内 —— 这正是当初否掉 FAExport 的原因：
/// 把 cookie 发给第三方服务器等于把账号交出去。
///
/// ⚠️ 这些 cookie 等价于账号密码，绝不要写进日志。
final class FACookieStore {

    static let shared = FACookieStore()

    /// 实际生效的持久化后端（界面上会显示，出问题时能一眼看出存哪了）
    enum Backend: String {
        case keychain = "Keychain"
        case file = "App 沙盒文件（Keychain 不可用）"
    }

    private let storageKey = "faios.cookies"
    private let fileName = "session.json"

    private let lock = NSLock()
    private var values: [String: String] = [:]

    private(set) var backend: Backend = .file
    /// 最近一次 Keychain 失败的状态码，供自检显示
    private(set) var keychainStatus: OSStatus = errSecSuccess

    private init() {
        load()
    }

    // MARK: - 读

    /// 拼成 `a=...; b=...; cf_clearance=...` 的形式；没有已知 cookie 时返回 nil
    var headerValue: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    var isLoggedIn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values["a"] != nil && values["b"] != nil
    }

    func value(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[name]
    }

    var cookieCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    /// 诊断用：`a=88b b=88b cf_clearance=210b` 这种（只报名字和长度，不泄露值）
    func describeCookies() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return "(none)" }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.utf8.count)b" }
            .joined(separator: " ")
    }

    /// 把内存里的 cookie 还原成 `HTTPCookie`，用来注入 WKWebView 的 cookie store。
    ///
    /// 为什么需要反向注入：`a` / `b` 是我们自己存在 Keychain 里的，WKWebView 那边
    /// 只有它自己见过的 cookie。重装/重启后 WebView 可能是「未登录」状态，
    /// 而用它去发私信会直接撞上 `System Message: Please log in!`（实测踩过）。
    var httpCookies: [HTTPCookie] {
        lock.lock()
        let snapshot = values
        lock.unlock()

        return snapshot.compactMap { name, value in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: ".\(FAURLs.domain)",
                .path: "/",
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(60 * 60 * 24 * 90),
            ]
            // cf_clearance 是 HttpOnly 的，注入时标上，尽量贴近服务端原样
            if name.hasPrefix("cf_") || name.hasPrefix("__cf") {
                props[.init("HttpOnly")] = "TRUE"
            }
            return HTTPCookie(properties: props)
        }
    }

    // MARK: - 写

    /// 我们真正需要的 cookie。`_ga` / `FCNEC` / `OAID` / `FA-Cache-Clear` 这些是第三方
    /// 分析/同意管理留下的，跟登录无关，收进来只会污染 header 并误导诊断。
    private static let allowedNames: Set<String> = ["a", "b", "cf_clearance", "__cf_bm"]

    /// 从 WebView 读到的 cookie 批量吸收（登录完成、挑战修复后都会调用）
    ///
    /// ⚠️ `a` 与 `b` 是**一对**会话值，必须同时更新。实测踩过的坑：WebView 里 FA 把 `b`
    /// 换成了新值而 `a` 已经不在了，我们照单全收 → 留下「旧 a + 新 b」的混合体，
    /// 服务端判定无效，表现为「App 显示已登录、所有请求却按访客返回 Login Required」。
    func absorb(httpCookies: [HTTPCookie]) {
        var incoming: [String: String] = [:]
        for cookie in httpCookies where cookie.domain.contains(FAURLs.domain) {
            guard Self.allowedNames.contains(cookie.name) else { continue }
            incoming[cookie.name] = cookie.value
        }
        guard !incoming.isEmpty else { return }

        lock.lock()
        var changed = false
        // 会话对：要么两个一起换，要么一个都不动
        if let a = incoming["a"], let b = incoming["b"] {
            if values["a"] != a { values["a"] = a; changed = true }
            if values["b"] != b { values["b"] = b; changed = true }
        }
        for (name, value) in incoming where name != "a" && name != "b" {
            if values[name] != value { values[name] = value; changed = true }
        }
        lock.unlock()
        if changed { persist() }
    }

    func set(_ name: String, value: String) {
        lock.lock()
        values[name] = value
        lock.unlock()
        persist()
    }

    func clear() {
        lock.lock()
        values.removeAll()
        lock.unlock()
        FAKeychain.delete(account: storageKey)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 只删一个 cookie（调试用：删掉 cf_clearance 可以人为制造一次 Cloudflare 挑战，
    /// 用来验证「挑战修复 → 重试」这条链路是否真的work，同时不弄丢登录态）
    @discardableResult
    func remove(_ name: String) -> Bool {
        lock.lock()
        let existed = values.removeValue(forKey: name) != nil
        lock.unlock()
        if existed { persist() }
        return existed
    }

    // MARK: - 持久化

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FAIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func persist() {
        lock.lock()
        let snapshot = values
        lock.unlock()
        guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }

        // 一级：Keychain
        let status = FAKeychain.set(data, account: storageKey)
        keychainStatus = status
        if status == errSecSuccess {
            backend = .keychain
            return
        }

        // 二级：文件。锁屏即加密（completeFileProtection）
        backend = .file
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // 连文件都写不了：至少内存里还有，本次运行可用
            FADebugLog.log("session persist failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        // 一级：Keychain
        let (status, data) = FAKeychain.data(account: storageKey)
        keychainStatus = status
        if let data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data),
           !decoded.isEmpty {
            values = Self.pruned(decoded)
            backend = .keychain
            return
        }

        // 二级：文件
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            values = Self.pruned(decoded)
            backend = .file
            return
        }

        // M1 曾把 cookie 明文塞进 UserDefaults：顺手迁走并抹掉旧位置
        if let legacy = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            values = Self.pruned(legacy)
            UserDefaults.standard.removeObject(forKey: storageKey)
            persist()
        }
    }

    /// 早期版本把网页里的第三方 cookie 也一股脑存了进来（GA、OneTrust 同意管理之类），
    /// 它们跟登录无关、只会污染 header 与诊断。这里按名单清掉，**其余一律保留** ——
    /// FA 将来要是多下发一个必需的 cookie，宁可留着也不能丢。
    private static func pruned(_ raw: [String: String]) -> [String: String] {
        var out = raw
        let drop: Set<String> = ["_ga", "_gid", "FCNEC", "FCCDCF", "OAID", "FA-Cache-Clear"]
        for key in raw.keys where drop.contains(key) || key.hasPrefix("_ga_") || key.hasPrefix("_gcl") {
            out.removeValue(forKey: key)
        }
        return out
    }

    /// 供自检显示：cookie 存哪、keychain 为什么没成
    func storageDescription() -> String {
        switch backend {
        case .keychain:
            return "Keychain（\(cookieCount) 条）"
        case .file:
            return "文件（Keychain 状态：\(FAKeychain.describe(keychainStatus))）"
        }
    }
}
