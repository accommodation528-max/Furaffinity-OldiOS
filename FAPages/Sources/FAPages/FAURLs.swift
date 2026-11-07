import Foundation

/// FurAffinity 的全部 URL 集中在这里（唯一允许出现字符串字面量的地方）。
public enum FAURLs {

    public static let domain = "furaffinity.net"

    /// https://www.furaffinity.net
    public static let base = URL(string: "https://www.\(domain)")!

    // MARK: - 页面

    public static var home: URL { base.appendingPathComponent("/") }

    public static var browse: URL { base.appendingPathComponent("/browse/") }

    public static var login: URL { base.appendingPathComponent("/login/") }

    public static var notifications: URL { base.appendingPathComponent("/msg/notifications/") }

    // MARK: - 投稿

    public static func submission(_ id: Int) -> URL {
        base.appendingPathComponent("/view/\(id)/")
    }

    public static func journal(_ id: Int) -> URL {
        base.appendingPathComponent("/journal/\(id)/")
    }

    // MARK: - 用户

    public static func user(_ name: String) -> URL {
        base.appendingPathComponent("/user/\(name)/")
    }

    public static func gallery(_ name: String, page: Int = 1) -> URL {
        base.appendingPathComponent("/gallery/\(name)/\(page)/")
    }

    public static func favorites(_ name: String, page: Int = 1) -> URL {
        base.appendingPathComponent("/favorites/\(name)/\(page)/")
    }

    public static func journals(_ name: String) -> URL {
        base.appendingPathComponent("/journals/\(name)/")
    }

    // MARK: - 搜索

    /// 搜索结果每页固定 72 条（比浏览页的 48 多）
    public static let searchPageSize = 72

    public static func search(_ query: String, page: Int = 1) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("/search/"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
        ]
        return c.url!
    }

    // MARK: - 资源

    /// 页面里的图片地址是协议相对的（`//t.furaffinity.net/...`），必须补成 https
    public static func absoluteImageURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    /// 把页面内的相对链接（`/view/123/`）解析成绝对地址
    public static func resolve(_ raw: String, relativeTo pageURL: URL) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        return URL(string: s, relativeTo: pageURL)?.absoluteURL
    }

    /// 缩略图档位就写在文件名里（`66962680@200-1794055731.jpg`），换成更大的档位只要改这个数字。
    /// 实测 @300 / @400 / @600 都可用（@150 会 301）。列表页给的是 @200，视网膜屏上偏糊。
    public static func thumbnailSized(_ url: URL, pixels: Int = 400) -> URL {
        let raw = url.absoluteString
        guard let range = raw.range(of: "@[0-9]+-", options: .regularExpression) else { return url }
        return URL(string: raw.replacingCharacters(in: range, with: "@\(pixels)-")) ?? url
    }
}
