import Foundation
import SwiftSoup

/// 投稿详情页（`/view/{id}/`）。
///
/// 与列表页的 `<figure>` 不同，详情页是「左侧大图 + 右侧信息面板」：
///
///     div.submission-content-inner
///     ├── div.submission-area.submission-image   → img#submissionImg（原图 + 600 预览）
///     └── div.submission-details
///         ├── section.submission-description
///         │   ├── .submission-description-header → 头像 / 标题 / 作者 / 发布时间
///         │   └── .section-body > .submission-description-text → 描述
///         ├── #submission-options               → Download 按钮
///         ├── .submission-content-stats         → 标签名 + 值（Category/Theme/Species/...）
///         ├── .submission-tags                  → 关键词
///         └── .submission-page-stats            → Views / Comments / Favorites
public struct FASubmissionDetail: Sendable {

    public let id: Int
    public let url: URL
    public let title: String
    public let authorName: String        // 显示名
    public let authorSlug: String        // URL 里的名字，大小写敏感
    public let authorURL: URL
    public let authorAvatarURL: URL?
    public let postedAt: Date?

    /// 原图（`d.furaffinity.net`）
    public let fullviewURL: URL?
    /// 600 宽预览（`t.furaffinity.net`），先显示它再换原图
    public let previewURL: URL?
    public let musicURL: URL?
    public let downloadURL: URL?

    /// 收藏动作：FA 把带 token 的收藏地址直接写在按钮的 href 上（文本 `+Fav` / `-Fav`），
    /// GET 一下就能切换，不需要逆向表单。
    public let favoriteURL: URL?
    public let isFavorited: Bool
    /// 「发私信」按钮指向的地址（`/newpm/{user}/`）
    public let noteURL: URL?

    public let tags: [String]
    public let descriptionText: String
    public let descriptionHTML: String

    public let views: Int?
    public let commentCount: Int?
    public let favoriteCount: Int?

    /// `.submission-content-stats` 里的属性对，例如 ["Category": "All", "Species": "All"]
    public let attributes: [(String, String)]

    public let kind: FASubmissionKind
    public let rating: FASubmissionRating

    public init(id: Int, url: URL, title: String, authorName: String, authorSlug: String,
                authorURL: URL, authorAvatarURL: URL?, postedAt: Date?,
                fullviewURL: URL?, previewURL: URL?, musicURL: URL?, downloadURL: URL?,
                favoriteURL: URL? = nil, isFavorited: Bool = false, noteURL: URL? = nil,
                tags: [String], descriptionText: String, descriptionHTML: String,
                views: Int?, commentCount: Int?, favoriteCount: Int?,
                attributes: [(String, String)], kind: FASubmissionKind, rating: FASubmissionRating) {
        self.id = id
        self.url = url
        self.title = title
        self.authorName = authorName
        self.authorSlug = authorSlug
        self.authorURL = authorURL
        self.authorAvatarURL = authorAvatarURL
        self.postedAt = postedAt
        self.fullviewURL = fullviewURL
        self.previewURL = previewURL
        self.musicURL = musicURL
        self.downloadURL = downloadURL
        self.favoriteURL = favoriteURL
        self.isFavorited = isFavorited
        self.noteURL = noteURL
        self.tags = tags
        self.descriptionText = descriptionText
        self.descriptionHTML = descriptionHTML
        self.views = views
        self.commentCount = commentCount
        self.favoriteCount = favoriteCount
        self.attributes = attributes
        self.kind = kind
        self.rating = rating
    }

    /// 送进查看器的图：有原图用原图，没有就退到预览
    public var imageURL: URL? { fullviewURL ?? previewURL }

    // MARK: - 解析

    public static func parse(_ html: String, from pageURL: URL) throws -> FASubmissionDetail {
        // 成人内容对未登录访客是个空壳登录页，先认出来
        try FAPageGuard.check(html)

        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        let id = Int(pageURL.path.drop { !$0.isNumber })
            ?? Int(((try? doc.select("figure[id]").first()?.attr("id")) ?? "").drop { !$0.isNumber })
        guard let submissionID = id else {
            throw FAPageError.missingElement("submission id")
        }

        // 标题：<div class="submission-title"><h2>Sunburn</h2></div>
        let title = ((try? doc.select("div.submission-title h2").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 作者：<a href="/user/spyro1mario/"><span class="c-usernameBlockSimple__displayName">Spyro1mario</span></a>
        let authorAnchor = try? doc.select(".submission-description-header a[href^=/user/]").first()
        let authorHref = (try? authorAnchor?.attr("href")) ?? ""
        let authorURL = FAURLs.resolve(authorHref, relativeTo: pageURL)
        guard let resolvedAuthorURL = authorURL else {
            throw FAPageError.missingElement("author link")
        }
        let authorSlug = resolvedAuthorURL.pathComponents.last(where: { $0 != "/" }) ?? ""
        let authorName = ((try? doc.select("span.c-usernameBlockSimple__displayName").first()?.text())
            ?? (try? authorAnchor?.text()) ?? authorSlug)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let avatarSrc = (try? doc.select("img.submission-user-icon").first()?.attr("src"))
            ?? (try? doc.select(".submission-description-artist img").first()?.attr("src"))
        let authorAvatarURL = FAURLs.absoluteImageURL(avatarSrc ?? "")

        // 发布时间：<span class="popup_date" data-time="1794055731" title="November 7, 2026 ...">
        var postedAt: Date?
        if let raw = try? doc.select("span.popup_date[data-time]").first()?.attr("data-time"),
           let seconds = TimeInterval(raw) {
            postedAt = Date(timeIntervalSince1970: seconds)
        }

        // 图：img#submissionImg 的 data-fullview-src（原图）/ data-preview-src（600 预览）
        let submissionImg = try? doc.select("img#submissionImg").first()
        let fullview = FAURLs.absoluteImageURL((try? submissionImg?.attr("data-fullview-src")) ?? "")
        var preview = FAURLs.absoluteImageURL((try? submissionImg?.attr("data-preview-src")) ?? "")
        if preview == nil {
            // 小说/音乐没有 data-preview-src，退到 src
            preview = FAURLs.absoluteImageURL((try? submissionImg?.attr("src")) ?? "")
        }

        // 音乐：<audio id="c-musicPlayer_inner" src="...">
        let musicSrc = (try? doc.select("audio#c-musicPlayer_inner").first()?.attr("src"))
            ?? (try? doc.select("audio").first()?.attr("src"))
        let musicURL = FAURLs.resolve(musicSrc ?? "", relativeTo: pageURL)

        // 下载按钮：文本是 "Download" 的 a
        var downloadURL: URL?
        for anchor in (try? doc.select("a").array()) ?? [] {
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text == "Download" else { continue }
            if let href = try? anchor.attr("href"), let url = FAURLs.resolve(href, relativeTo: pageURL) {
                downloadURL = url
                break
            }
        }

        // 操作条：#submission-options 里的 +Fav / -Fav / Note
        // 登录后才存在（未登录时这一条为空），所以缺失不算解析失败
        var favoriteURL: URL?
        var isFavorited = false
        var noteURL: URL?
        for anchor in (try? doc.select("#submission-options a[href]").array()) ?? [] {
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let href = try? anchor.attr("href"),
                  let url = FAURLs.resolve(href, relativeTo: pageURL) else { continue }
            switch text {
            case "+Fav":
                favoriteURL = url
                isFavorited = false
            case "-Fav":
                favoriteURL = url
                isFavorited = true
            case "Note":
                noteURL = url
            default:
                break
            }
        }

        // 标签：.submission-tags 里指向 /search/@keywords 的链接
        var tags: [String] = []
        var seenTags = Set<String>()
        for anchor in (try? doc.select(".submission-tags a[href^=/search/]").array()) ?? [] {
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seenTags.insert(text.lowercased()).inserted else { continue }
            tags.append(text)
        }

        // 描述
        let descriptionElement = try? doc.select(".submission-description-text").first()
        let descriptionText = ((try? descriptionElement?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionHTML = (try? descriptionElement?.html()) ?? ""

        // 属性对：<span class="highlight"><span>Category</span>…</span><span><span>All</span>…</span>
        var attributes: [(String, String)] = []
        if let stats = try? doc.select(".submission-content-stats").first() {
            let labels = ((try? stats.select("span.highlight > span").array()) ?? [])
                .map { ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let values = ((try? stats.select("> span").array()) ?? [])
                .filter { ((try? $0.className()) ?? "").contains("highlight") == false }
                .flatMap { ((try? $0.select("> span").array()) ?? []).isEmpty
                    ? [((try? $0.text()) ?? "")]
                    : ((try? $0.select("> span").array()) ?? []).map { ((try? $0.text()) ?? "") } }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for (index, label) in labels.enumerated() where index < values.count && !label.isEmpty {
                attributes.append((label, values[index]))
            }
        }

        // 计数：<div class="submission-page-stats"><div title="Views"><div>8</div><div class="highlight">Views</div></div>…
        func statCount(_ title: String) -> Int? {
            guard let node = try? doc.select(".submission-page-stats div[title=\(title)]").first() else {
                return nil
            }
            let raw = ((try? node.select("> div").first()?.text()) ?? "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(raw)
        }
        let views = statCount("Views")
        let commentCount = statCount("Comments")
        let favoriteCount = statCount("Favorites")

        // 类型：.submission-area 的修饰 class
        let areaClass = (try? doc.select("div.submission-area").first()?.className()) ?? ""
        let kind = FASubmissionKind.from(className: areaClass)

        // 分级：详情页写作 <div class="font-large inline c-contentRating--general">General</div>，
        // 和 Views/Comments/Favorites 并列在 .submission-page-stats 里。
        // 注意别扫全页：侧栏新闻块也会出现 c-contentRating--*（那是 journal 的分级）。
        let ratingClass = ((try? doc.select(".submission-page-stats div[class]").array()) ?? [])
            .map { ((try? $0.className()) ?? "") }
            .first { $0.contains("c-contentRating--") } ?? ""
        let rating = FASubmissionRating.fromDetailClass(ratingClass.isEmpty ? areaClass : ratingClass)

        return FASubmissionDetail(
            id: submissionID,
            url: pageURL,
            title: title,
            authorName: authorName.isEmpty ? authorSlug : authorName,
            authorSlug: authorSlug,
            authorURL: resolvedAuthorURL,
            authorAvatarURL: authorAvatarURL,
            postedAt: postedAt,
            fullviewURL: fullview,
            previewURL: preview,
            musicURL: musicURL,
            downloadURL: downloadURL,
            favoriteURL: favoriteURL,
            isFavorited: isFavorited,
            noteURL: noteURL,
            tags: tags,
            descriptionText: descriptionText,
            descriptionHTML: descriptionHTML,
            views: views,
            commentCount: commentCount,
            favoriteCount: favoriteCount,
            attributes: attributes,
            kind: kind,
            rating: rating
        )
    }
}
