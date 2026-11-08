import SwiftUI
import WebKit
import FAPages

/// 发私信 —— 必须在真实 WebView 里走一遍。
///
/// 为什么不能像收藏那样直接 POST：`/newpm/{user}/` 的表单里挂着 Cloudflare Turnstile
/// （`div.cf-turnstile[data-sitekey]`）。实测纯 URLSession POST `/msg/send/`
/// 拿到的是 `Error sending a note. CAPTCHA verification failed.` —— token 只能由页面里的
/// Turnstile 脚本生成，我们伪造不了。
///
/// 所以这里的做法是：把 FA 自己的写信页加载进来 → 用 JS 把我们填好的主题/正文写进表单 →
/// 等 Turnstile 自己算出 token → 提交表单 → 读返回页上的系统提示判断成功与否。
/// 用户看到的是一个会自动关掉的「正在发送」sheet，不需要在网页里手填。
struct ComposeNoteWebView: View {

    let recipient: String
    let subject: String
    let message: String
    var onFinish: (Bool, String?) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ComposeWebModel

    init(recipient: String, subject: String, message: String,
         onFinish: @escaping (Bool, String?) -> Void = { _, _ in }) {
        self.recipient = recipient
        self.subject = subject
        self.message = message
        self.onFinish = onFinish
        _model = StateObject(wrappedValue: ComposeWebModel(recipient: recipient,
                                                           subject: subject,
                                                           message: message))
    }

    var body: some View {
        NavigationView {
            ZStack {
                ComposeWebContainer(webView: model.webView)

                switch model.phase {
                case .loading, .submitting:
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(model.phase == .submitting ? "正在发送…" : "正在通过 Cloudflare 验证…")
                            .font(.footnote)
                            .foregroundColor(.white)
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(14)
                case .manual:
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap")
                            Text("点一下页面里的人机验证")
                                .font(.caption)
                            Button("提交") { model.submitNow() }
                                .font(.caption).buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        Spacer()
                    }
                case .failed(let text):
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 26))
                            .foregroundColor(.orange)
                        Text(text)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                        Button("关闭") {
                            onFinish(false, text)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(16)
                    .padding(.horizontal, 28)
                case .done:
                    EmptyView()
                }
            }
            .navigationTitle("正在发送")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        onFinish(false, "已取消")
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            model.onSuccess = {
                onFinish(true, nil)
                dismiss()
            }
            model.start()
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - 模型

@MainActor
final class ComposeWebModel: NSObject, ObservableObject, WKNavigationDelegate {

    enum Phase: Equatable {
        case loading
        case submitting
        /// Turnstile 没自己算完 → 把页面交还给用户，让他点一下验证再按页面上的 Send Note
        case manual
        case failed(String)
        case done
    }

    @Published private(set) var phase: Phase = .loading

    var onSuccess: (() -> Void)?

    let webView: WKWebView

    private let recipient: String
    private let subject: String
    private let message: String

    private var submitted = false
    private var polls = 0
    private var timer: Timer?
    private var loadFallback: Timer?
    private var prefilled = false
    private var finished = false

    init(recipient: String, subject: String, message: String) {
        self.recipient = recipient
        self.subject = subject
        self.message = message

        let config = WKWebViewConfiguration()
        // 与登录、常驻 WebView 共用同一个 data store —— 否则这里是「未登录」的空白身份
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = FAChallenge.userAgent()
        web.isOpaque = false
        web.backgroundColor = .clear
        self.webView = web
        super.init()
        web.navigationDelegate = self
    }

    func start() {
        guard !submitted, webView.url == nil else { return }
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("收信人用户名不能为空")
            return
        }
        Task { @MainActor in
            // 先把 Keychain 里的 a/b 注回 WebView，否则这里打开的是「未登录」的写信页，
            // 提交后会得到 System Message: Please log in!
            await FAWebCookieBridge.injectStoredCookies()
            guard !finished else { return }
            webView.load(URLRequest(url: FAURLs.newNote(to: trimmed)))
            self.armLoadFallback()
        }
    }

    /// 兜底：FA 页面上挂着会一直转的第三方资源，`didFinish` 有时几十秒都不来
    /// （2026-11-08 真机实测：页面早就画好了、表单也在，但 phase 卡在 loading，
    /// 遮罩挡住页面，人机验证点不到）。所以别等 didFinish —— 到点就自己接管。
    private func armLoadFallback() {
        loadFallback?.invalidate()
        loadFallback = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished, !self.submitted else { return }
                if self.phase == .loading {
                    self.prefillAndWaitForCaptcha()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        loadFallback?.invalidate()
        loadFallback = nil
    }

    /// 手动模式下的「提交」按钮：token 已经有了，直接让表单提交
    func submitNow() {
        guard !submitted else { return }
        submitForm()
    }

    // MARK: 导航

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 关键判别：**还在 `/newpm/` 上就是写信页本身**，不是提交后的结果页。
        // 曾经写成「phase == .manual 就判结果」，结果页面一加载完就立刻误判成
        // 「FA 没有接受这次发送」——人机验证根本还没机会点。
        let path = webView.url?.path ?? ""
        let stillOnCompose = path.contains("/newpm/")

        if submitted || !stillOnCompose {
            finishAfterSubmit()
            return
        }
        if phase == .loading {
            prefillAndWaitForCaptcha()
        }
    }

    /// DOM 一提交就先把表单填了（此时 `didFinish` 往往还没来）。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !submitted, !finished, phase == .loading else { return }
        prefillAndWaitForCaptcha()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !submitted { fail("写信页加载失败：\(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !submitted { fail("写信页加载失败：\(error.localizedDescription)") }
    }

    // MARK: 填表 + 等 Turnstile

    private func prefillAndWaitForCaptcha() {
        // didCommit / didFinish / 12 秒兜底 三条路都会走到这儿，只走一次
        guard !prefilled, !submitted, !finished else { return }
        prefilled = true
        loadFallback?.invalidate()
        loadFallback = nil
        // 立刻撤掉遮罩，把页面交给人去点人机验证
        phase = .manual
        attemptPrefill(remaining: 15)
    }

    /// 填表要重试：`didCommit` 时 DOM 往往还没长出来（实测 2026-11-08 14:01：
    /// 收信人是服务端填好的，但主题和正文是空的 → 提交必然失败）。
    private func attemptPrefill(remaining: Int) {
        guard !submitted, !finished else { return }
        let js = """
        (function () {
          var f = document.getElementById('note-form');
          if (!f) { return 'noform'; }
          var s = f.querySelector('input[name=subject]');
          var m = f.querySelector('textarea');
          var t = f.querySelector('input[name=to]');
          if (s && !s.value) { s.value = \(jsString(subject)); s.dispatchEvent(new Event('input', {bubbles:true})); }
          if (m && !m.value) { m.value = \(jsString(message)); m.dispatchEvent(new Event('input', {bubbles:true})); }
          if (t && !t.value) { t.value = \(jsString(recipient)); }
          var hasSubject = !!(s && s.value);
          var hasMessage = !!(m && m.value);
          return (hasSubject ? '1' : '0') + (hasMessage ? '1' : '0');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, !self.submitted, !self.finished else { return }
            let state = (result as? String) ?? "00"
            if state.contains("1") {
                self.startPollingToken()
                return
            }
            if remaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.attemptPrefill(remaining: remaining - 1)
                }
            } else {
                // 填不进去也别卡死：页面还在人手里，可以自己填好再点「提交」
                self.startPollingToken()
            }
        }
    }

    /// Turnstile 算出 token 之后它会被塞进一个隐藏 input（`cf-turnstile-response`）。
    /// 我们只等这个值出现，不碰 iframe 里的勾选框（那在 closed shadow root 里，抓不到）。
    private func startPollingToken() {
        timer?.invalidate()
        polls = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollToken() }
        }
        pollToken()
    }

    private func pollToken() {
        guard !submitted, !finished else { return }
        polls += 1
        if polls == 40 {   // ≈24s 还没算出 token → 把页面交还给人（但继续盯着 token）
            phase = .manual
        }
        if polls > 400 {  // ≈4 分钟还没动静，彻底放弃
            fail("人机验证一直没有完成，先放弃这次发送。")
            return
        }

        let js = """
        (function () {
          var el = document.querySelector('#note-form input[name="cf-turnstile-response"]')
                || document.querySelector('input[name="cf-turnstile-response"]');
          return el ? (el.value || '') : '';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, !self.submitted else { return }
            let token = (result as? String) ?? ""
            if token.count > 20 {
                self.submitForm()
            }
        }
    }

    private func submitForm() {
        guard !submitted else { return }
        submitted = true
        timer?.invalidate()
        timer = nil
        phase = .submitting

        // 用 requestSubmit 而不是 submit()：前者会触发 submit 事件与按钮的值，
        // 与用户真点「Send Note」等价。老 WebKit 没有 requestSubmit 时退回 submit()。
        let js = """
        (function () {
          var f = document.getElementById('note-form') || document.querySelector('form.note-form');
          if (!f) { return 'noform'; }
          if (f.requestSubmit) { f.requestSubmit(); } else { f.submit(); }
          return 'ok';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error, !(error.localizedDescription.contains("JavaScript")) {
                self.fail("提交失败：\(error.localizedDescription)")
                return
            }
            guard (result as? String) != "noform" else {
                self.fail("没找到写信表单（页面结构可能变了）")
                return
            }
            // 提交后页面会跳转，didFinish 会回来 —— 那时再判结果
            self.armSubmitTimeout()
        }
    }

    private func armSubmitTimeout() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.polls += 1
                if self.polls > 40 {
                    self.fail("提交后 40 秒没有反应（可能是网络或 Cloudflare 又拦了一次）")
                }
            }
        }
    }

    /// POST 落地后的页面：成功＝回到私信列表；失败有三种形态
    /// （`notice-message`、`System Error`、以及**表单还在**＝FA 根本没接受这次发送）。
    private func finishAfterSubmit() {
        let js = """
        (function () {
          var notice = '';
          var m = document.querySelector('section.notice-message div.redirect-message');
          if (m) { notice = m.innerText || m.textContent || ''; }

          if (!notice) {
            var secs = document.querySelectorAll('section');
            for (var i = 0; i < secs.length; i++) {
              var h = secs[i].querySelector('.section-header h2');
              var t = h ? (h.innerText || h.textContent || '') : '';
              if (t.indexOf('System Error') >= 0 || t.indexOf('System Message') >= 0) {
                var b = secs[i].querySelector('.section-body');
                var bt = b ? (b.innerText || b.textContent || '') : '';
                notice = t + '：' + bt;
                break;
              }
            }
          }

          var hasForm = !!document.getElementById('note-form');
          var hasList = !!document.getElementById('notes-list');
          var bodyText = document.body ? (document.body.innerText || document.body.textContent || '') : '';

          return JSON.stringify({
            notice: notice,
            title: document.title || '',
            url: location.href,
            hasForm: hasForm,
            hasList: hasList,
            emptyInbox: bodyText.indexOf('There are no notes to display') >= 0,
            html: document.documentElement.outerHTML || ''
          });
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            var notice = ""
            var hasForm = true
            var stillOnCompose = true
            var sawList = false
            if let raw = result as? String,
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                notice = ((obj["notice"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                hasForm = (obj["hasForm"] as? Bool) ?? false
                sawList = (obj["hasList"] as? Bool) ?? (obj["emptyInbox"] as? Bool) ?? false
                let url = (obj["url"] as? String) ?? ""
                stillOnCompose = url.contains("/newpm/")
                if let html = obj["html"] as? String, !html.isEmpty {
                    // 真机上唯一能看的现场：把结果页落盘，用 SSH 取回来判断到底成功没有
                    _ = FADiag.dump(html, name: "compose-result")
                }
            }

            if !notice.isEmpty {
                // 页面里的「Click here to go back」是 FA 的返回按钮，不属于提示本身
                if let range = notice.range(of: "Click here to go back") {
                    notice = String(notice[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let lowered = notice.lowercased()
                let failureWords = ["error", "failed", "cannot", "can not", "not allowed",
                                    "please log in", "invalid", "must be logged"]
                if failureWords.contains(where: { lowered.contains($0) }) {
                    self.fail(notice.replacingOccurrences(of: "\n", with: " "))
                    return
                }
            }

            // 只有「离开写信页 + 看到私信列表」才算真的发出去了。
            // 实测（2026-11-08 13:51）：FA 在没拿到 Turnstile token 时会**静默地**
            // 把写信页原样再渲染一遍（无任何提示），照旧判定成功就是假成功。
            if sawList && !hasForm && !stillOnCompose {
                self.succeed()
            } else if hasForm || stillOnCompose {
                self.fail("FA 没有接受这次发送（写信页还在）。多半是人机验证没通过——"
                          + "回到写信页，点一下页面里的勾选框再试。")
            } else {
                self.succeed()
            }
        }
    }

    // MARK: 收尾

    private func succeed() {
        guard !finished else { return }
        finished = true
        stop()
        phase = .done
        onSuccess?()
    }

    private func fail(_ text: String) {
        guard !finished else { return }
        finished = true
        stop()
        phase = .failed(text)
    }

    /// 把 Swift 字符串安全地塞进 JS 字面量
    private func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())   // 去掉外层 [ ]
    }
}

// MARK: - 容器

struct ComposeWebContainer: UIViewRepresentable {

    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
