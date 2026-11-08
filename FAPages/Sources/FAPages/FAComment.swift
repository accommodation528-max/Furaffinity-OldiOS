import Foundation
import SwiftSoup

/// 一条评论。
///
/// FA 的评论区在投稿页和日志页用同一套结构（只是容器 id 不同）：
///
///     <div id="comments-submission|comments-journal" class="comments-list">
///       <div class="comment_container" data-timestamp="…">
///         <a id="cid:61771922"></a>
///         <comment-container>
///           <div class="avatar"><a href="/user/x/"><img class="comment_useravatar" src="//a…"></a></div>
///           <div class="comment-content">
///             <comment-username>…<a class="c-usernameBlock__displayName">名字</a></comment-username>
///             <comment-title>自定义标题</comment-title>
///             <comment-date><span class="popup_date" data-time="…"></span></comment-date>
///             <comment-user-text><div class="user-submitted-links">正文</div></comment-user-text>
///           </div>
///         </comment-container>
///       </div>
///
/// 回复是**嵌在父评论里**的（同一个 `.comment_container` 类），所以用祖先链算出缩进层级。
public struct FAComment: Sendable, Identifiable {

    /// `cid:61771922` 里的数字部分
    public let id: String
    public let authorName: String
    public let authorSlug: String
    public let authorURL: URL?
    public let avatarURL: URL?
    /// 「Word Wizard!」这类自定义标题，多数评论没有
    public let title: String?
    public let body: String
    public let postedAt: Date?
    /// 0 = 顶层；1 = 对楼上的回复，以此类推
    public let depth: Int

    public init(id: String, authorName: String, authorSlug: String, authorURL: URL?,
                avatarURL: URL?, title: String?, body: String, postedAt: Date?, depth: Int) {
        self.id = id
        self.authorName = authorName
        self.authorSlug = authorSlug
        self.authorURL = authorURL
        self.avatarURL = avatarURL
        self.title = title
        self.body = body
        self.postedAt = postedAt
        self.depth = depth
    }
}

public enum FAComments {

    /// 评论区里出现这句就是「楼主关了评论」
    static let disabledMarker = "Comment posting has been disabled"

    public static func areCommentsDisabled(in html: String) -> Bool {
        html.contains(disabledMarker)
    }

    /// 按文档顺序解析出全部评论（含回复）。
    /// 单条评论结构坏掉时跳过它，不要因为一条坏评论丢掉整页。
    public static func parse(_ html: String, from pageURL: URL) throws -> [FAComment] {
        try FAPageGuard.check(html)

        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        let containers = (try? doc.select("div.comment_container").array()) ?? []
        var comments: [FAComment] = []
        comments.reserveCapacity(containers.count)

        for container in containers {
            let body = ((try? container.select("comment-user-text").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 被删掉的评论只剩骨架，正文为空，别把它显示成一条空气泡
            guard !body.isEmpty else { continue }

            let anchorID = ((try? container.select("a[id^=cid:]").first()?.attr("id")) ?? "")
            let id = anchorID.replacingOccurrences(of: "cid:", with: "")

            let userAnchor = try? container.select("a.c-usernameBlock__displayName").first()
            let href = (try? userAnchor?.attr("href")) ?? ""
            let authorURL = FAURLs.resolve(href, relativeTo: pageURL)
            let authorSlug = authorURL?.pathComponents.last(where: { $0 != "/" }) ?? ""
            let displayName = ((try? userAnchor?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let avatar = FAURLs.absoluteImageURL((try? container.select("img.comment_useravatar").first()?.attr("src")) ?? "")

            let rawTitle = ((try? container.select("comment-title").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? nil : rawTitle

            var postedAt: Date?
            if let raw = try? container.select("span.popup_date[data-time]").first()?.attr("data-time"),
               let seconds = TimeInterval(raw) {
                postedAt = Date(timeIntervalSince1970: seconds)
            }

            comments.append(FAComment(
                id: id,
                authorName: displayName.isEmpty ? authorSlug : displayName,
                authorSlug: authorSlug,
                authorURL: authorURL,
                avatarURL: avatar,
                title: title,
                body: body,
                postedAt: postedAt,
                depth: depth(of: container)
            ))
        }
        return comments
    }

    /// 往上数还有几层 `.comment_container`（回复嵌在父评论里）
    private static func depth(of element: Element) -> Int {
        var depth = 0
        var node = element.parent()
        while let current = node {
            if let className = try? current.className(), className.split(separator: " ").contains("comment_container") {
                depth += 1
            }
            node = current.parent()
        }
        return depth
    }
}
