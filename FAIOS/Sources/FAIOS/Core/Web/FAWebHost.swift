import Foundation
import Combine
import SwiftUI
import WebKit
import FAPages

/// 常驻的 WKWebView：唯一职责是「让 Cloudflare 认得这台机器」。
///
/// 三条来自参考项目实测的硬结论（都在真机上复现过）：
/// 1. **冷启动直接发请求 10/10 得 403**，而同一个 `cf_clearance` 在 WebView 把首页加载完之后就 200
///    → 所以启动时要让它跑一次首页，这不是「顺便」，是必需。
/// 2. **它必须是全尺寸的**：缩成 1×1 时 viewport 只剩几 CSS 像素，Turnstile 的容器会塌成 0 高，
///    被动挑战永远过不了。
/// 3. **同一时刻只允许一次导航**：两次导航交错会读到对方的页面，`@MainActor` 挡不住跨 `await`。
///
/// 它不参与任何业务渲染 —— 正文仍然由 `FAHTTP` 拉、`FAPages` 解析。
@MainActor
final class FAWebHost: NSObject, ObservableObject {

    static let shared = FAWebHost()

    let webView: WKWebView

    /// 是否持有可用的登录 cookie（`a` + `b`）
    @Published private(set) var isLoggedIn: Bool

    /// 正在续期 Cloudflare 信任
    @Published private(set) var isRefreshing = false

    // 导航串行化：同一时刻只能有一个 load 在跑
    private var busy = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    // 当前这次导航的等待者
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutToken = 0

    private var lastWarmUp: Date?

    /// 诊断用：最近一次从 WebView 同步过来的 cookie 摘要（名字:长度），显示在自检里
    private(set) var lastSyncedSummary = "(未同步)"

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // 持久化 cookie，重启仍在
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: config)
        // UA 必须与 FAHTTP 逐字节一致，否则 cf_clearance 白拿
        wv.customUserAgent = FAChallenge.userAgent()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.isUserInteractionEnabled = false
        wv.allowsBackForwardNavigationGestures = false

        self.webView = wv
        self.isLoggedIn = FACookieStore.shared.isLoggedIn
        super.init()
        wv.navigationDelegate = self
    }

    // MARK: - 公开接口

    /// 冷启动后跑一次：加载首页只为续 Cloudflare 信任，内容不关心。
    func warmUpIfNeeded(force: Bool = false) async {
        if !force, let last = lastWarmUp, Date().timeIntervalSince(last) < 60 { return }
        isRefreshing = true
        _ = await load(FAURLs.home)
        lastWarmUp = Date()
        isRefreshing = false
    }

    /// 加载一个页面并等到 `didFinish`（或超时）。
    @discardableResult
    func load(_ url: URL, timeout: TimeInterval = FAChallenge.Throttle.challengeTimeout) async -> Bool {
        await waitForTurn()
        defer { releaseTurn() }

        let finished = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            finishContinuation = cont
            timeoutToken += 1
            let token = timeoutToken

            // 超时兜底：WebView 有时既不 finish 也不 fail（挑战页会 hold 住导航）
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.timeoutToken == token, self.finishContinuation != nil else { return }
                self.finishNavigation(success: false)
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            self.webView.load(request)
        }

        if finished { await syncCookies() }
        return finished
    }

    /// 把 WebView 里的 cookie（含 `cf_clearance`）同步给 `FAHTTP` 用的那份存储。
    func syncCookies() async {
        let cookies = await allCookies()
        let fa = cookies.filter { $0.domain.contains(FAURLs.domain) }
        let a = fa.first { $0.name == "a" }?.value ?? "-"
        let b = fa.first { $0.name == "b" }?.value ?? "-"
        lastSyncedSummary = "weba=\(a) webb=\(b) 共\(fa.count)个"
        guard !fa.isEmpty else { return }
        FACookieStore.shared.absorb(httpCookies: fa)
        updateLoginState()
    }

    /// 退出登录：清 Keychain 里的快照，并删掉 WebView 里的 FA cookie。
    func clearCookies() async {
        let cookies = await allCookies()
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies where cookie.domain.contains(FAURLs.domain) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { cont.resume() }
            }
        }
        FACookieStore.shared.clear()
        lastWarmUp = nil
        updateLoginState()
        NotificationCenter.default.post(name: .faiosLoginDidChange, object: nil)
    }

    // MARK: - 内部

    private func allCookies() async -> [HTTPCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cont.resume(returning: $0) }
        }
    }

    private func updateLoginState() {
        let logged = FACookieStore.shared.isLoggedIn
        guard logged != isLoggedIn else { return }
        isLoggedIn = logged
        NotificationCenter.default.post(name: .faiosLoginDidChange, object: nil)
    }

    private func finishNavigation(success: Bool) {
        guard let cont = finishContinuation else { return }
        finishContinuation = nil
        timeoutToken += 1          // 让挂着的超时闭包失效
        cont.resume(returning: success)
    }

    private func waitForTurn() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func releaseTurn() {
        if turnWaiters.isEmpty {
            busy = false
        } else {
            // 名额直接转交给下一个等待者，别先释放再抢（中间会插进别人）
            turnWaiters.removeFirst().resume()
        }
    }
}

// MARK: - 导航回调

extension FAWebHost: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(success: false)
    }
}

// MARK: - 挂进视图层级

/// 把常驻 WebView 挂到窗口里（放在 TabView 底下、被不透明的界面盖住）。
///
/// 注意：**不能**用 `.opacity(0)` 或 `.hidden`，也不能让它离开 window ——
/// 那样 WebKit 会把它当成不可见页面，挑战脚本不跑。
struct FAWebHostView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to container: UIView) {
        let wv = FAWebHost.shared.webView
        guard wv.superview !== container else { return }
        wv.frame = container.bounds
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(wv)
    }
}
