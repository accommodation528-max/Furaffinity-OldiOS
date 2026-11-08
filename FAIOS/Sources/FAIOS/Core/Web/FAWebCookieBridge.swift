import Foundation
import WebKit
import FAPages

/// 把 Keychain 里的会话 cookie 注回 WKWebView。
///
/// 两个方向都要通：
/// - WebView → App：登录完成后 `FACookieStore.absorb(httpCookies:)`
/// - App → WebView：这里。没有它，重装/重启后 WebView 是「未登录」，
///   用它去发私信会得到 `System Message: Please log in!`（实测踩过），
///   用它去过 Cloudflare 也达不到「用已登录身份续信任」的目的。
@MainActor
enum FAWebCookieBridge {

    /// 注入一次（幂等：同一个 cookie 覆盖写）
    @discardableResult
    static func injectStoredCookies(into store: WKWebsiteDataStore = .default()) async -> Int {
        let cookies = FACookieStore.shared.httpCookies
        guard !cookies.isEmpty else { return 0 }
        let cookieStore = store.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(cookie) { cont.resume() }
            }
        }
        return cookies.count
    }

    /// 诊断用：读出 WebView 里现有的与我们相关的 cookie 摘要（只报名字与长度）
    static func describeWebCookies(in store: WKWebsiteDataStore = .default()) async -> String {
        let all = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        let ours = all.filter { $0.domain.contains(FAURLs.domain) }
        guard !ours.isEmpty else { return "weba=- webb=- 共0个" }
        let a = ours.first { $0.name == "a" }?.value.count ?? 0
        let b = ours.first { $0.name == "b" }?.value.count ?? 0
        return "weba=\(a)b webb=\(b)b 共\(ours.count)个"
    }
}
