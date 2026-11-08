import Foundation
import SwiftSoup

/// 一篇 Journal（FA 的日记/公告，艺术家通常用它发接稿公告）。
///
/// 结构（实测 `/journal/11447701/`）：
///
///     <div class="c-Journal__header section-header">
///       <div id="c-journalTitleTop">
///         <span id="c-journalTitleTop__subject"><h3>标题</h3></span>
///       </div>
///       <div id="c-journalTitleBottom">
///         <span id="c-journalTitleTop__date"><span class="popup_date" data-time="…">…</span></span>
///         <span id="c-journalTitleTop__contentRating" class="c-contentRating--general">General</span>
///       </div>
///     </div>
///     <div class="journal-content user-submitted-links"> 正文 </div>
///
/// 作者信息不在正文里，而在页面顶部的 `userpage-nav-*` 自定义标签里（跟用户页同一套）。
public struct FAJournal: Sendable {

    public let id: Int
    public let url: URL
    public let title: String
    public let authorName: String
    public let authorSlug: String
    public let authorAvatarURL: URL?
    public let postedAt: Date?
    public let rating: FASubmissionRating
    /// 正文纯文本（保留换行）
    public let bodyText: String
    /// 评论（Journal 用 `#comments-journal`，结构与投稿一样）
    public let comments: [FAComment]
    public let commentsDisabled: Bool

    public init(id: Int, url: URL, title: String, authorName: String, authorSlug: String,
                authorAvatarURL: URL?, postedAt: Date?, rating: FASubmissionRating,
                bodyText: String, comments: [FAComment], commentsDisabled: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.authorName = authorName
        self.authorSlug = authorSlug
        self.authorAvatarURL = authorAvatarURL
        self.postedAt = postedAt
        self.rating = rating
        self.bodyText = bodyText
        self.comments = comments
        self.commentsDisabled = commentsDisabled
    }
}

public enum FAJournals {

    public static func parse(_ html: String, from pageURL: URL) throws -> FAJournal {
        try FAPageGuard.check(html)

        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw FAPageError.malformedHTML(String(describing: error)) }

        let id = Int(pageURL.pathComponents.last(where: { $0 != "/" }) ?? "") ?? 0

        let title = ((try? doc.select("#c-journalTitleTop__subject h3").first()?.text())
            ?? (try? doc.select("#c-journalTitleTop__subject").first()?.text())
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let dateElement = try? doc.select("#c-journalTitleTop__date span.popup_date").first()
        var postedAt: Date?
        if let raw = try? dateElement?.attr("data-time"), let seconds = TimeInterval(raw), seconds > 0 {
            postedAt = Date(timeIntervalSince1970: seconds)
        }

        var rating = FASubmissionRating.general
        if let className = try? doc.select("#c-journalTitleTop__contentRating").first()?.className() {
            rating = FASubmissionRating.fromDetailClass(className)
        }

        // 作者：页顶的 userpage-nav-* 区块（和用户页同一套自定义标签）
        var authorSlug = ""
        var authorName = ""
        var avatarURL: URL?
        if let nav = try? doc.select("userpage-nav-header").first() {
            if let href = try? nav.select("userpage-nav-avatar a[href^=/user/]").first()?.attr("href") {
                authorSlug = href.split(separator: "/").last.map(String.init) ?? ""
            }
            authorName = ((try? nav.select("a.c-usernameBlock__displayName span.js-displayName").first()?.text())
                ?? (try? nav.select("a.c-usernameBlock__displayName").first()?.text())
                ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let src = try? nav.select("userpage-nav-avatar img[src]").first()?.attr("src") {
                avatarURL = FAURLs.absoluteImageURL(src)
            }
        }
        if authorName.isEmpty { authorName = authorSlug }

        // 正文：.journal-content 是 HTML 片段，要保留换行地转纯文本
        var bodyText = ""
        if let body = try? doc.select("div.journal-content").first() {
            bodyText = FAHTMLText.plain(body)
        }

        let comments = (try? FAComments.parse(html, from: pageURL)) ?? []
        let disabled = FAComments.areCommentsDisabled(in: html)

        guard !title.isEmpty || !bodyText.isEmpty else { throw FAPageError.missingElement("journal title") }

        return FAJournal(id: id, url: pageURL, title: title, authorName: authorName,
                         authorSlug: authorSlug, authorAvatarURL: avatarURL, postedAt: postedAt,
                         rating: rating, bodyText: bodyText, comments: comments,
                         commentsDisabled: disabled)
    }
}
