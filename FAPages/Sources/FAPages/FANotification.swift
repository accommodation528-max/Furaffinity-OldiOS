import Foundation
import SwiftSoup

/// 站内消息中心（`/msg/*`）里的一条通知。
///
/// `/msg/others/` 由若干 `section.section_container#messages-*` 组成，
/// 每块里是 `ul.message-stream > li`，一行一条：
///
///     <li>
///       <div class="table">
///         <div class="cell …checkbox"><input name="journals[]" value="11447701"></div>
///         <div class="cell user-submitted-links">
///           <a href="/journal/11447701/"><em class="journal_subject">标题</em></a>
///           (<span class="c-contentRating--general">G</span>)
///           posted by <span class="c-usernameBlockSimple"><a href="/user/x/">…名字…</a></span>
///           <span class="popup_date" data-time="…"></span>
///         </div>
///       </div>
///     </li>
///
/// **只有非空的分组才会渲染**，所以解析器不能假设某个分组一定存在。
public struct FANotification: Sendable {

    public enum Kind: String, Sendable {
        case journal
        case submission
        case comment
        case shout
        case watch
        case favorite
        case other

        /// 分组 id（`messages-journals`）→ 类型
        static func from(sectionID: String) -> Kind {
            let s = sectionID.lowercased()
            if s.contains("journal") { return .journal }
            if s.contains("submission") { return .submission }
            if s.contains("comment") { return .comment }
            if s.contains("shout") { return .shout }
            if s.contains("watch") { return .watch }
            if s.contains("favorite") { return .favorite }
            return .other
        }
    }

    public let kind: Kind
    /// 页面上原始的分组标题（Journals / Submission comments …），用于分区显示
    public let sectionTitle: String
    /// 勾选框里的 id（投稿/日志的 id），去重和已读用
    public let id: String?
    public let title: String
    public let url: URL?
    public let authorName: String?
    public let authorSlug: String?
    public let postedAt: Date?
    public let rating: FASubmissionRating?

    public init(kind: Kind, sectionTitle: String, id: String?, title: String, url: URL?,
                authorName: String?, authorSlug: String?, postedAt: Date?, rating: FASubmissionRating?) {
        self.kind = kind
        self.sectionTitle = sectionTitle
        self.id = id
        self.title = title
        self.url = url
        self.authorName = authorName
        self.authorSlug = authorSlug
        self.postedAt = postedAt
        self.rating = rating
    }
}

public enum FANotifications {

    /// 有没有东西可看：`/msg/others/` 空的时候只有标题和一句「没有通知」。
    public static func parse(_ html: String, from pageURL: URL) throws -> [FANotification] {
        try FAPageGuard.check(html)

        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        var notifications: [FANotification] = []
        for section in (try? doc.select("section.section_container[id^=messages-]").array()) ?? [] {
            let sectionID = (try? section.attr("id")) ?? ""
            let kind = FANotification.Kind.from(sectionID: sectionID)
            let header = ((try? section.select("div.section-header .highlight").first()?.text()) ?? kind.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for row in (try? section.select("ul.message-stream > li").array()) ?? [] {
                guard let notification = parseRow(row, pageURL: pageURL, kind: kind, sectionTitle: header) else {
                    continue
                }
                notifications.append(notification)
            }
        }
        return notifications
    }

    private static func parseRow(_ row: Element, pageURL: URL,
                                 kind: FANotification.Kind,
                                 sectionTitle: String) -> FANotification? {
        // 主链接：第一个指向站内的 a（跳过 # 和 javascript:）
        var url: URL?
        var title = ""
        for anchor in (try? row.select("a[href]").array()) ?? [] {
            let href = (try? anchor.attr("href")) ?? ""
            guard !href.isEmpty, !href.hasPrefix("#"), !href.hasPrefix("javascript:") else { continue }
            guard let resolved = FAURLs.resolve(href, relativeTo: pageURL) else { continue }
            url = resolved
            // 标题优先取 <em class="journal_subject">，否则用链接文本
            title = ((try? anchor.select("em").first()?.text()) ?? (try? anchor.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { break }
        }

        guard let resolvedURL = url else { return nil }

        let id = (try? row.select("input[type=checkbox]").first()?.attr("value")).flatMap { $0.isEmpty ? nil : $0 }

        let userAnchor = try? row.select("span.c-usernameBlockSimple a[href^=/user/]").first()
        let userHref = (try? userAnchor?.attr("href")) ?? ""
        let authorURL = FAURLs.resolve(userHref, relativeTo: pageURL)
        let authorSlug = authorURL?.pathComponents.last(where: { $0 != "/" })
        let authorName = ((try? row.select("span.c-usernameBlockSimple__displayName").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var postedAt: Date?
        if let raw = try? row.select("span.popup_date[data-time]").first()?.attr("data-time"),
           let seconds = TimeInterval(raw) {
            postedAt = Date(timeIntervalSince1970: seconds)
        }

        let ratingClass = ((try? row.select("span[class^=c-contentRating--]").first()?.className()) ?? "")
        let rating = ratingClass.isEmpty ? nil : FASubmissionRating.fromDetailClass(ratingClass)

        return FANotification(
            kind: kind,
            sectionTitle: sectionTitle,
            id: id,
            title: title,
            url: resolvedURL,
            authorName: authorName.isEmpty ? nil : authorName,
            authorSlug: authorSlug,
            postedAt: postedAt,
            rating: rating
        )
    }
}

/// 从任意已登录页面里认出「我是谁」。
///
/// 顶栏的账号菜单是 `<a id="my-username" href="#">My FA ( Nosense528 )</a>`，
/// 括号里是显示名；同页一定有个 `/user/{slug}/` 的链接，用 slug 拼收藏/画廊地址。
public enum FAAccount {

    public struct Identity: Sendable, Equatable {
        public let displayName: String
        public let slug: String
    }

    public static func parse(_ html: String, from pageURL: URL) throws -> Identity? {
        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        // 显示名：a#my-username 的文本里去掉「My FA (」和「)」
        var displayName = ((try? doc.select("a#my-username").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = displayName.lastIndex(of: "("), let close = displayName.lastIndex(of: ")"), open < close {
            displayName = String(displayName[displayName.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // slug：账号下拉菜单里的「My Userpage」就是自己的用户页
        //（`a#my-username` 的 href 是 "#"，拿不到 slug）
        var slug = ""
        let menuAnchors = (try? doc.select("a[href]").array()) ?? []
        for anchor in menuAnchors {
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text == "My Userpage" || text == "我的主页" else { continue }
            let href = (try? anchor.attr("href")) ?? ""
            guard href.contains("/user/") else { continue }
            slug = href.split(separator: "/").last.map(String.init) ?? ""
            break
        }
        // 兜底：显示名本身就是 slug 时（FA 上极常见），直接用它
        if slug.isEmpty && !displayName.isEmpty {
            let candidate = displayName.lowercased()
            if (try? doc.select("a[href=/user/\(candidate)/]").first()) != nil {
                slug = candidate
            }
        }
        guard !slug.isEmpty else { return nil }
        return Identity(displayName: displayName.isEmpty ? slug : displayName, slug: slug)
    }
}
