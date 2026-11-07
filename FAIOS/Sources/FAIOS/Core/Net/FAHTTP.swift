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
/// 2. **并发不超 3、间隔不小于 350ms**：FA 的限速是真实存在的
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

    private let session: URLSession
    private let gate = AsyncSemaphore(limit: FAChallenge.Throttle.maxConcurrent)
    private var lastRequestTime: Date?

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
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开接口

    /// 取一个页面的 HTML。
    /// - Parameter url: 绝对地址
    /// - Returns: 页面源码
    /// - Throws: `FAHTTPError.challenge` 时上层应走修复流程，**重新调用本方法**而不是自己重试
    public func fetchHTML(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw FAHTTPError.decoding
    }

    public func fetchData(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await performOnce(url)
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

    // MARK: - 单次请求

    private func performOnce(_ url: URL) async throws -> Data {
        await gate.acquire()
        defer { Task { await gate.release() } }

        await waitForSpacing()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let cookies = FACookieStore.shared.headerValue {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FAHTTPError.transport(error)
        }

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

    /// 强制两次请求之间至少隔 `minimumSpacingMS`
    private func waitForSpacing() async {
        let minimum = Double(FAChallenge.Throttle.minimumSpacingMS) / 1000
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimum {
                try? await Task.sleep(nanoseconds: UInt64((minimum - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }
}
