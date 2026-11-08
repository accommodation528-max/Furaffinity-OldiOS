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

    // MARK: - 消息中心（需要登录）

    /// 站内通知（评论、收藏、关注……）
    public static var msgNotifications: URL { base.appendingPathComponent("/msg/others/") }

    /// 关注对象的新投稿
    public static var msgSubmissions: URL { base.appendingPathComponent("/msg/submissions/") }

    /// 私信（Notes）收件箱
    public static var notesInbox: URL { base.appendingPathComponent("/msg/pms/") }

    public static var notesSent: URL { base.appendingPathComponent("/msg/pms/sent/") }

    public static var notesCompose: URL { base.appendingPathComponent("/controls/notes/new/") }

    /// 发私信的表单 action（POST，字段 key/to/subject/message）
    public static var sendNote: URL { base.appendingPathComponent("/msg/send/") }

    /// 「给某人写私信」的预填页面（GET 一次可拿到 CSRF key）
    public static func newNote(to name: String) -> URL {
        base.appendingPathComponent("/newpm/\(name)/")
    }

    /// 用户头像的**无日期**地址。站点通常给 `a.furaffinity.net/<yyyyMMdd>/<user>.gif`，
    /// 列表里拿不到日期，这条不带日期的地址能直接命中。
    public static func avatar(_ name: String) -> URL? {
        URL(string: "https://a.furaffinity.net/\(name).gif")
    }

    /// 账号设置页（顺带用来取自己的用户名）
    public static var controls: URL { base.appendingPathComponent("/controls/") }

    /// 我的投稿（含统计）
    public static func submissions(_ name: String, page: Int = 1) -> URL {
        base.appendingPathComponent("/\(name)/submissions/\(page)/")
    }

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

    /// 标签搜索。站内标签点进去就是 `@keywords` 运算符（网页版 JS 也是这么拼的），
    /// 多个标签用空格连起来表示「同时包含」。注意扩展运算符要求 `q` 里带前缀，不能裸传标签名。
    public static func tag(_ tags: String, page: Int = 1) -> URL {
        let cleaned = tags
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@keywords", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return search("@keywords " + cleaned, page: page)
    }

    // MARK: - 关注

    /// 我关注的人（`/watchlist/by/{me}/`）。和 `/msg/submissions/` 的「关注流投稿」是两件事：
    /// 这里是「谁在被我关注」的名单，带每人的投稿数。
    public static func watching(_ name: String, page: Int = 1) -> URL {
        base.appendingPathComponent("/watchlist/by/\(name)/\(page)/")
    }

    /// 关注我的人（`/watchlist/to/{me}/`）
    public static func watchers(_ name: String, page: Int = 1) -> URL {
        base.appendingPathComponent("/watchlist/to/\(name)/\(page)/")
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
