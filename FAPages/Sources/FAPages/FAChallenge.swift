import Foundation

/// Cloudflare 挑战的识别与请求身份常量。
///
/// 背景（参考项目实测结论）：
/// * `cf_clearance` 与 **User-Agent 逐字节绑定** → App 内所有请求（URLSession 与 WKWebView）
///   必须使用同一个 UA，否则 cookie 白拿。
/// * 区分「被动挑战」（无 UI，1.5–3 秒自动过）与「交互挑战」（需要用户点一下）。
public enum FAChallenge {

    /// 统一的 UA 尾巴。FA 员工靠这个识别第三方客户端流量；也方便我们自己在服务器日志里认领请求。
    public static let uaSuffix = "FAiOS/0.1"

    /// 完整 UA：iOS 15 Safari 的壳 + 我们的标识。
    /// 改这里之前先想清楚：改了会导致已有的 cf_clearance 全部失效。
    public static func userAgent(appVersion: String = "0.1.0") -> String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/15.6 Mobile/15E148 Safari/604.1 "
        + "\(uaSuffix.replacingOccurrences(of: "0.1", with: appVersion))"
    }

    // MARK: - 识别

    /// 挑战页的硬特征。刻意**不用** `turnstile` 这个词：
    /// 正常的 /login 页面本身就内嵌了 Turnstile 控件（实测含 4 处），误判会把登录页当成挑战页。
    private static let challengeMarkers = [
        "_cf_chl_opt",              // 挑战配置对象，最可靠
        "cf-browser-verification",  // 老版挑战页
        "challenge-platform",       // 挑战脚本
        "cf_chl_",                  // 挑战系列资源
    ]

    /// 匹配 `cType:"interactive"`、`"cType":"interactive"`、`cType: 'interactive'` 等写法
    private static let interactiveMarker = #"cType["']?\s*:\s*["']interactive["']"#

    /// 这个响应是不是 Cloudflare 挑战（而不是真正的页面）
    public static func isChallenge(status: Int, body: String) -> Bool {
        // 200 也可能是挑战页（JS 挑战），所以不能只看状态码
        guard status == 403 || status == 503 || status == 200 else { return false }
        let sample = body.prefix(20_000)   // 特征总在 <head> 里，不用扫全文
        return challengeMarkers.contains { sample.contains($0) }
    }

    /// 挑战是否需要用户交互。
    /// 注意 `_cf_chl_opt.cType` 是**一个下划线**，不是 `__cf_chl_opt`。
    public static func requiresInteraction(body: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: interactiveMarker) else { return false }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return re.firstMatch(in: body, range: range) != nil
    }

    // MARK: - 节流参数
    //
    // FA 限速是真实存在的：同一 IP 连发请求会直接 curl timeout（实测）。
    // 这两个数字是保守值，宁可慢一点也不要被拉黑。
    public enum Throttle {
        /// 同时在途的请求数
        public static let maxConcurrent = 3
        /// 两次请求之间的最小间隔（毫秒）
        public static let minimumSpacingMS = 350
        /// 挑战解决最多等多久（秒）——参考项目实测 solve 需要 1.5–25 秒
        public static let challengeTimeout: TimeInterval = 30
    }
}
