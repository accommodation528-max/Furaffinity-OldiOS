import Foundation
import FAPages

/// FA 的两个登录 cookie（`a` = 会话，`b` = 另一份绑定值）以及其他 Cloudflare cookie。
///
/// 存储策略：
/// * 内存里始终有一份，请求时直接拼 Cookie 头
/// * 持久化到 **Keychain**（M2 实现），现在是 UserDefaults 占位
///
/// ⚠️ 这些 cookie 等价于账号密码，绝不要写进日志、也别发给任何第三方
/// （这就是当初否掉 FAExport 的原因）。
final class FACookieStore {

    static let shared = FACookieStore()

    private let storageKey = "faios.cookies"
    private var lock = NSLock()
    private var values: [String: String] = [:]

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

    // MARK: - 写

    /// 从 `Set-Cookie` 响应头里吸收 cookie（WKWebView 登录完成后调用）
    func absorb(httpCookies: [HTTPCookie]) {
        lock.lock()
        var changed = false
        for cookie in httpCookies where cookie.domain.contains(FAURLs.domain) || cookie.domain == FAURLs.domain {
            // cf_clearance 与 UA 绑定，但存下来没坏处：UA 是不变的
            values[cookie.name] = cookie.value
            changed = true
        }
        lock.unlock()
        if changed { persist() }
    }

    /// 直接写入（从 WKWebView 的 cookieStore 读出来时用）
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
        persist()
    }

    // MARK: - 持久化（M2 换成 Keychain）

    private func persist() {
        lock.lock()
        let snapshot = values
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: storageKey)
    }

    private func load() {
        if let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            values = stored
        }
    }
}
