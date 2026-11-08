import Foundation
import SwiftSoup

/// 关注名单里的一个人。
///
/// 这个页面（`/watchlist/by/{me}/`）跟「关注流投稿」（`/msg/submissions/`）不是一回事：
/// 这里是**人名列表**，那边是**作品流**。网页版只有前者，手机端两个都该有。
public struct FAWatchEntry: Sendable, Equatable, Identifiable {
    /// url 里的用户名（小写）
    public let slug: String
    /// 页面上显示的名字（保留用户原本的大小写）
    public let displayName: String

    public var id: String { slug }
    public var url: URL { FAURLs.user(slug) }

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

/// 一页关注名单。空名单（比如没人关注你）也是合法结果，不是错误。
public struct FAWatchlistPage: Sendable, Equatable {
    /// 页面自带的标题，比如 "Users Nosense528 is watching" / "Users that are watching Nosense528"
    public let title: String
    public let entries: [FAWatchEntry]
    public let nextPageURL: URL?

    public var isEmpty: Bool { entries.isEmpty }
}

public enum FAWatchlist {

    /// 解析 `/watchlist/by/…` 与 `/watchlist/to/…` —— 两者结构完全一样，只有标题不同。
    ///
    /// 每一行是：
    /// ```html
    /// <div class="watch-list-items watch-row new-section inline">
    ///   ~<span class="c-usernameBlockSimple username-underlined">
    ///       <a href="/user/amby/"><span class="c-usernameBlockSimple__displayName" title=" amby ">amby0es</span></a>
    ///    </span>
    /// </div>
    /// ```
    /// 注意 `title` 属性里带首尾空格，而文字节点是显示名 —— 两者都可能有用，优先用 `title`（更干净）。
    public static func parse(_ html: String, from pageURL: URL) throws -> FAWatchlistPage {
        try FAPageGuard.check(html)

        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw FAPageError.malformedHTML(String(describing: error)) }

        let title = ((try? doc.select("div.section-header h2").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var entries: [FAWatchEntry] = []
        var seen = Set<String>()

        for row in try doc.select("div.watch-list-items, div.watch-list > div") {
            guard let anchor = try row.select("a[href^=/user/]").first(),
                  let rawHref = try? anchor.attr("href") else { continue }
            guard let slug = slug(from: rawHref), !slug.isEmpty else { continue }

            // 显示名优先取 title 属性（页面会给它加首尾空格），没有就退到文字
            let named = try row.select("span.c-usernameBlockSimple__displayName").first()
            let titleAttr = ((try? named?.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = ((try? named?.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let display = !titleAttr.isEmpty ? titleAttr : (!text.isEmpty ? text : slug)

            guard seen.insert(slug).inserted else { continue }
            entries.append(FAWatchEntry(slug: slug, displayName: display))
        }

        // 大部分人的关注名单只有一页；有分页表单时才去认（复用列表页那套表单解析规则）
        var nextPageURL: URL?
        if let pagination = try? Self.pagination(in: doc, pageURL: pageURL) {
            nextPageURL = pagination.next
        }

        return FAWatchlistPage(title: title, entries: entries, nextPageURL: nextPageURL)
    }

    /// 关注名单的分页：表单里 `Next` 按钮或 `a` 文本含 Next 都算。
    /// 用的是和列表页同一套「从 hidden input 重建 query」的规则，避免手写 page=N 猜错。
    private static func pagination(in doc: Document, pageURL: URL) throws -> (prev: URL?, next: URL?) {
        guard let form = try doc.select("form[method=GET]").first() else { return (nil, nil) }

        var next: URL?
        var prev: URL?
        for element in try form.select("button, input[type=submit]").array() {
            let text = ((try? element.text()) ?? (try? element.attr("value")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = Self.url(fromForm: form, button: element, pageURL: pageURL) else { continue }
            if text.localizedCaseInsensitiveContains("next") { next = url }
            if text.localizedCaseInsensitiveContains("prev") { prev = url }
        }
        return (prev, next)
    }

    /// 表单 + 按钮 → URL。规则与 `FASubmissionsPage` 保持一致：
    /// hidden input 决定 query，按钮自己的 `name/value` 覆盖同名项（搜索页的页码就长在按钮上）。
    private static func url(fromForm form: Element, button: Element?, pageURL: URL) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }

        var items: [URLQueryItem] = []
        let inputs = (try? form.select("input").array()) ?? []
        for input in inputs {
            let type = ((try? input.attr("type")) ?? "").lowercased()
            guard type.isEmpty || type == "hidden" || type == "submit" else { continue }
            guard let name = try? input.attr("name"), !name.isEmpty else { continue }
            let value = (try? input.attr("value")) ?? ""
            items.append(URLQueryItem(name: name, value: value))
        }

        if let button {
            let name = (try? button.attr("name")) ?? ""
            if !name.isEmpty {
                let value = (try? button.attr("value")) ?? ""
                items.removeAll { $0.name == name }
                items.append(URLQueryItem(name: name, value: value))
            }
        }

        guard !items.isEmpty else { return nil }
        components.queryItems = items
        return components.url
    }

    /// `/user/amby/` → `amby`
    static func slug(from href: String) -> String? {
        let parts = href.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "user"), parts.count > index + 1 else { return nil }
        return parts[index + 1]
    }
}
