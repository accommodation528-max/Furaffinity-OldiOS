import Foundation
import FAPages

/// FA 的网络层：**快路径**。
///
/// 只负责「带上正确的身份、别把人惹毛、把结果拿回来」。
/// 遇到 Cloudflare 挑战时**不自己解决**，而是抛 `FAHTTPError.challenge` 交给上层
/// （M2 的 ChallengeCoordinator）统一处理——因为挑战修复涉及常驻 WKWebView，
/// 不属于这一层。
///
/// 三个必须守住的不变式：
/// 1. **UA 唯一**：所有请求（含 WebView）用同一个 UA，否则 cf_clearance 作废
/// 2. **页面并发不超 3、间隔不小于 350ms**：FA 的限速是真实存在的；
///    静态资源（`t.`/`a.`/`d.` 子域）走另一条快车道，见下方 `Lane`
/// 3. **挑战不交给解析器**：识别到挑战就抛错，别把挑战页当页面解析
public actor FAHTTP {

    public static let shared = FAHTTP()

    // MARK: - 错误

    public enum FAHTTPError: Error, CustomStringConvertible {
        /// 需要过 Cloudflare。interactive=true 表示要弹 UI 让用户点
        case challenge(interactive: Bool)
        /// 401/需要登录
        case notLoggedIn
        case http(Int)
        case transport(Error)
        case decoding

        public var description: String {
            switch self {
            case .challenge(let i): return "需要 Cloudflare 挑战（\(i ? "交互" : "被动")）"
            case .notLoggedIn:      return "需要登录"
            case .http(let s):      return "HTTP \(s)"
            case .transport(let e): return "网络错误: \(e.localizedDescription)"
            case .decoding:         return "页面编码无法识别"
            }
        }
    }

    // MARK: - 状态

    private let config: URLSessionConfiguration
    private var session: URLSession

    /// 两条车道：页面和静态资源。
    ///
    /// FA 的限速针对的是**页面的动态渲染**（一个请求要后端生成 100KB+ HTML）。
    /// 缩略图是同一批 CDN 上的静态文件，按 350ms 一张串着取，一屏 12 张就要 4.2 秒 ——
    /// 真机冷启动时第一屏几乎全是灰格子，瓶颈就在这里。
    /// 浏览器自己也是每个域名开 6 条连接并行取图，所以这里对静态资源放行：
    /// 并发 6、间隔 80ms，页面那条路保持 3 / 350ms 不变。
    private let pageGate = AsyncSemaphore(limit: FAChallenge.Throttle.maxConcurrent)
    private let assetGate = AsyncSemaphore(limit: 6)
    private var pageLastRequest: Date?
    private var assetLastRequest: Date?

    /// 失败重试次数（不含首次）
    private let maxRetries = 2

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": FAChallenge.userAgent(),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
        ]
        // 自己管 cookie，不用 HTTPCookieStorage，避免和 WKWebView 的 store 打架
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let proxy = FAHTTP.readProxySpec()
        FAHTTP.applyProxy(proxy, to: config)
        self.config = config
        self.session = URLSession(configuration: config)
        self.proxySpec = proxy
    }

    /// 当前生效的代理（"host:port"）。空 = 直连。
    private var proxySpec: String?

    /// 代理设置存在 UserDefaults（非隔离、init 里就能读）。
    /// 注意：手动 cp -R 安装时 UserDefaults 不可靠（见 FAStore 的注释），
    /// 但 TrollStore 正规安装后它是真的；这只是一条「网络出口」配置，丢了重填即可。
    public nonisolated static let proxyStoreKey = "fa.net.proxy"

    public nonisolated static func readProxySpec() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: proxyStoreKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// 把 "host:port" 变成 URLSession 能用的代理字典。
    ///
    /// 为什么要有这个开关：FA 的域名在这台机器所处的网络里会被 DNS 污染成
    /// 173.252.248.244（Facebook 的 IP），直连必然超时。手机上的代理 App 通常只对
    /// 「系统流量」生效，而我们要能单独把 App 的请求指到某个 HTTP 代理（如 PC 上的 Clash 7890）。
    nonisolated static func applyProxy(_ spec: String?, to config: URLSessionConfiguration) {
        guard let spec, !spec.isEmpty else {
            config.connectionProxyDictionary = nil
            return
        }
        // 支持三种写法：
        //   host:port            → HTTP/HTTPS 代理（Clash 的 mixed-port 就是这种）
        //   http://host:port     → 同上，显式写法
        //   socks://host:port    → SOCKS5（Surge/Quantumult 之类的本地端口常见 1080）
        var body = spec
        var isSOCKS = false
        for prefix in ["socks5://", "socks://", "http://", "https://"] where body.lowercased().hasPrefix(prefix) {
            isSOCKS = prefix.hasPrefix("socks")
            body = String(body.dropFirst(prefix.count))
            break
        }
        let parts = body.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            config.connectionProxyDictionary = nil
            return
        }
        let host = String(parts[0])
        if isSOCKS {
            config.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
                "SOCKSVersion": 5,
            ]
        } else {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        }
    }

    /// 运行时改代理：重建 session（URLSession 的代理配置不能热改）。
    public func setProxy(_ spec: String?) {
        let normalized = (spec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : spec
        UserDefaults.standard.set(normalized, forKey: FAHTTP.proxyStoreKey)
        FAHTTP.applyProxy(normalized, to: config)
        proxySpec = normalized
        session.invalidateAndCancel()
        session = URLSession(configuration: config)
    }

    public func currentProxySpec() -> String? { proxySpec }

    /// 丢掉连接池里现存的连接（挑战修复用）。
    ///
    /// Cloudflare 判的是**连接**而不是请求：solve 花 1.5–25 秒，
    /// 这期间新开的连接带的还是旧的 `cf_clearance`，所以必须把连接池整个换掉再重试。
    /// URLSession 没有「清空连接」的 API，换一个 session 是等价且唯一可靠的做法。
    public func resetConnections() {
        session.invalidateAndCancel()
        session = URLSession(configuration: config)
    }

    // MARK: - 公开接口

    /// 取一个页面的 HTML。
    /// - Parameter url: 绝对地址
    /// - Returns: 页面源码
    /// - Throws: `FAHTTPError.challenge` 时上层应走修复流程，**重新调用本方法**而不是自己重试
    public func fetchHTML(_ url: URL) async throws -> String {
        try await html(from: try await fetchData(url))
    }

    /// 提交一个表单（`application/x-www-form-urlencoded`），返回结果页 HTML。
    ///
    /// FA 的发私信 / 回复 / 发评论都是 POST 表单（页面上藏在 `<form>` 里的 hidden `key`
    /// 就是 CSRF token，必须先 GET 原页面拿到它再 POST）。
    /// 302 由 URLSession 自动跟随，拿到的已经是动作生效后的页面。
    public func submitForm(_ url: URL, fields: [(String, String)]) async throws -> String {
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        let encoded = comps.percentEncodedQuery ?? ""
        var body = encoded
        // URLComponents 会把空格编成 "%20"，x-www-form-urlencoded 更常见的是 "+"；
        // FA 两种都认，但统一用 "+" 少踩一个坑。
        body = body.replacingOccurrences(of: "%20", with: "+")
        let data = body.data(using: .utf8) ?? Data()
        return try await html(from: try await fetchData(url, method: "POST", body: data))
    }

    private func html(from data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw FAHTTPError.decoding
    }

    public func fetchData(_ url: URL) async throws -> Data {
        try await fetchData(url, method: "GET", body: nil)
    }

    private func fetchData(_ url: URL, method: String, body: Data?) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await performOnce(url, method: method, body: body)
            } catch let error as FAHTTPError {
                switch error {
                case .transport, .http(500...599):
                    // 只有传输层错误和 5xx 值得重试；挑战/登录问题重试是浪费
                    guard attempt < maxRetries else { throw error }
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                default:
                    throw error
                }
            }
        }
    }

    /// 裸网络探针：**不经过**信号量、cookie、UA 定制，直接用新的 URLSession 打几个最小请求。
    ///
    /// 为什么需要：TrollStore 重装后出现过「所有请求都超时」，
    /// 分不清是「App 根本没有网络」还是「我们的车道/会话被卡住」。
    /// 这个探针只回答一个问题：这台机器上，这个进程能不能发出 HTTPS 请求。
    /// 会同时试 `URLSession.shared` 与 ephemeral，并换一个域名做对照 ——
    /// 三个结果放在一起就能把「网络被挡住」「某个配置有问题」「只有 FA 不通」区分开。
    public func probe(_ url: URL) async -> String {
        var lines: [String] = []

        func attempt(_ label: String, _ target: URL, _ configuration: URLSessionConfiguration?) async {
            let began = Date()
            let s: URLSession
            if let configuration {
                s = URLSession(configuration: configuration)
            } else {
                s = URLSession.shared
            }
            do {
                let (data, response) = try await s.data(from: target)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                lines.append("PROBE \(label) ok status=\(status) \(data.count)B \(Int(Date().timeIntervalSince(began) * 1000))ms")
            } catch {
                lines.append("PROBE \(label) fail \(Int(Date().timeIntervalSince(began) * 1000))ms \(error.localizedDescription)")
            }
            if configuration != nil { s.invalidateAndCancel() }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        await attempt("shared/fa", url, nil)
        await attempt("ephemeral/fa", url, cfg)
        if let control = URL(string: "https://example.com/") {
            let cfg2 = URLSessionConfiguration.ephemeral
            cfg2.timeoutIntervalForRequest = 10
            await attempt("shared/control", control, nil)
            await attempt("ephemeral/control", control, cfg2)
        }
        let controlHost = "https://example.com/"
        lines.append("DNS " + Self.describeResolution(for: url) + " / " + (URL(string: controlHost).map(Self.describeResolution(for:)) ?? "?"))
        return lines.joined(separator: " | ")
    }

    /// 把域名解析成 IPv4，用来判断「是不是被 DNS 劫持到了 198.18.x.x 这种假 IP」。
    /// 真机排查过一次「只有 FA 不通、别的站都好」，先看解析结果比猜网络栈快得多。
    private nonisolated static func describeResolution(for url: URL) -> String {
        guard let host = url.host else { return "?" }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return "\(host)=resolve-failed"
        }
        defer { freeaddrinfo(result) }
        var ips: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node, ips.count < 3 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                ips.append(String(cString: buffer))
            }
            node = current.pointee.ai_next
        }
        return "\(host)=\(ips.joined(separator: ","))"
    }

    // MARK: - 单次请求

    private enum Lane {
        case page
        case asset
    }

    /// 静态资源（缩略图 / 原图 / 头像）走快车道，页面走慢车道
    private static func lane(for url: URL) -> Lane {
        guard let host = url.host?.lowercased() else { return .page }
        return host.hasPrefix("t.") || host.hasPrefix("a.") || host.hasPrefix("d.")
            ? .asset
            : .page
    }

    private func performOnce(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        let lane = Self.lane(for: url)
        let began = Date()
        FADiag.record("REQ  \(method) \(url.path) lane=\(lane == .asset ? "asset" : "page")")
        if lane == .asset {
            await assetGate.acquire()
        } else {
            await pageGate.acquire()
        }
        defer {
            Task {
                if lane == .asset { await assetGate.release() } else { await pageGate.release() }
            }
        }
        FADiag.record("GATE \(url.path) waited=\(Int(Date().timeIntervalSince(began) * 1000))ms")

        await waitForSpacing(lane)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let cookies = FACookieStore.shared.headerValue {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            FADiag.record("ERR  \(url.path) after=\(Int(Date().timeIntervalSince(began) * 1000))ms \(error.localizedDescription)")
            throw FAHTTPError.transport(error)
        }
        FADiag.record("RES  \(url.path) \(data.count)B total=\(Int(Date().timeIntervalSince(began) * 1000))ms")

        guard let http = response as? HTTPURLResponse else {
            throw FAHTTPError.http(-1)
        }

        // Cloudflare 可能用 200/403/503 返回挑战页，必须先判挑战再判状态码
        if let text = String(data: data.prefix(20_000), encoding: .utf8),
           FAChallenge.isChallenge(status: http.statusCode, body: text) {
            throw FAHTTPError.challenge(interactive: FAChallenge.requiresInteraction(body: text))
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw FAHTTPError.notLoggedIn
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FAHTTPError.http(http.statusCode)
        }

        if let cookies = http.allHeaderFields["Set-Cookie"] as? String {
            // URLSession 已经把 Set-Cookie 合并过；这里只处理简单的 "name=value; ..." 形式
            _ = cookies
        }
        return data
    }

    /// 强制两次同类请求之间至少隔 `minimumSpacingMS`（静态资源另有一条更紧的间隔）
    private func waitForSpacing(_ lane: Lane) async {
        let minimum = lane == .asset
            ? 0.08
            : Double(FAChallenge.Throttle.minimumSpacingMS) / 1000
        let last = lane == .asset ? assetLastRequest : pageLastRequest

        if let last {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimum {
                try? await Task.sleep(nanoseconds: UInt64((minimum - elapsed) * 1_000_000_000))
            }
        }
        if lane == .asset {
            assetLastRequest = Date()
        } else {
            pageLastRequest = Date()
        }
    }
}
