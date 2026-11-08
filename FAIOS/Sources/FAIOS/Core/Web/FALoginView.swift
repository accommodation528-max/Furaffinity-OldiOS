import SwiftUI
import WebKit
import FAPages

/// 登录界面：在**应用内**的网页里登录，账号密码不经过本 App。
///
/// 为什么不能用账号密码直接 POST：
/// `/login` 页面里内嵌了 Cloudflare Turnstile（实测 4 处），
/// 没有浏览器环境就过不了，硬撞只会得到一个空响应。
///
/// 登录成功后 FA 会下发 `a` / `b` 两个 cookie —— 它们是后续所有请求的身份。
@MainActor
final class FALoginModel: NSObject, ObservableObject, WKNavigationDelegate {

    let webView: WKWebView

    @Published private(set) var loggedIn = false
    @Published private(set) var errorText: String?

    var onSuccess: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        // 与常驻 WebView 共用同一个 data store —— cookie 与 cf_clearance 才是一致的
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = FAChallenge.userAgent()
        wv.allowsBackForwardNavigationGestures = true

        self.webView = wv
        super.init()
        wv.navigationDelegate = self
    }

    func start() {
        // 先把网页里残留的 FA cookie 清干净再进登录页。
        // 不清的话，网页可能停在「b 已轮换、a 已消失」的半登录态（这正是会话失效的成因），
        // 登录页会以为还在登录中，不会让我们重新输入账号。
        Task {
            await clearFACookies()
            webView.load(URLRequest(url: FAURLs.login))
        }
    }

    private func clearFACookies() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        for cookie in cookies where cookie.domain.contains(FAURLs.domain) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { cont.resume() }
            }
        }
    }

    func reload() {
        errorText = nil
        webView.reload()
    }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkCookies() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // 取消（比如用户点了别的链接）不算错
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        errorText = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorText = "网页进程被系统回收了，点右上角重试"
    }

    // MARK: - 判定登录成功

    private func checkCookies() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let fa = cookies.filter { $0.domain.contains(FAURLs.domain) }
        guard fa.contains(where: { $0.name == "a" }), fa.contains(where: { $0.name == "b" }) else { return }

        // 存下来（Keychain）：从这里开始网页和网络层共用一个身份
        FACookieStore.shared.absorb(httpCookies: fa)
        FADiag.record("LOGIN ok names=\(fa.map(\.name).sorted().joined(separator: ","))")
        loggedIn = true
        onSuccess?()
    }
}

struct FALoginView: View {

    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var model = FALoginModel()

    var body: some View {
        NavigationView {
            ZStack {
                WebViewBox(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)

                if let error = model.errorText {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error).font(.footnote)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.92))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding()
                    }
                }
            }
            .navigationTitle("登录 FurAffinity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重试") { model.reload() }
                }
            }
        }
        .onAppear {
            model.onSuccess = {
                // 让常驻 WebView 用新身份重跑一次首页：cf_clearance 与登录态一起续上
                Task {
                    await FAWebHost.shared.warmUpIfNeeded(force: true)
                    NotificationCenter.default.post(name: .faiosLoginDidChange, object: nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            model.start()
        }
    }
}

/// 把外部持有的 WKWebView 塞进 SwiftUI（不自己 new，方便复用同一个 webView）
struct WebViewBox: UIViewRepresentable {

    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard webView.superview !== uiView else { return }
        webView.frame = uiView.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        uiView.addSubview(webView)
    }
}
