import Foundation
import SwiftSoup

/// 投稿列表页：首页、/browse、/search、画廊、收藏页 —— 它们是同一套 `<figure>` 结构。
public struct FASubmissionsPage: Sendable {

    public let submissions: [FASubmission]
    /// 下一页地址（已解析成绝对 URL）；最后一页为 nil
    public let nextPageURL: URL?
    /// 上一页地址；第一页为 nil
    public let previousPageURL: URL?

    public init(submissions: [FASubmission], nextPageURL: URL?, previousPageURL: URL?) {
        self.submissions = submissions
        self.nextPageURL = nextPageURL
        self.previousPageURL = previousPageURL
    }

    // MARK: - 解析

    public static func parse(_ html: String, from pageURL: URL = FAURLs.browse) throws -> FASubmissionsPage {
        try FAPageGuard.check(html)

        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        let figures: Elements
        do {
            figures = try doc.select("figure")
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        var submissions: [FASubmission] = []
        submissions.reserveCapacity(figures.size())
        for figure in figures.array() {
            if let s = try? parseFigure(figure, pageURL: pageURL) {
                submissions.append(s)
            }
            // 单条坏掉不影响整页——FA 偶尔会插广告位/统计块
        }

        let (prev, next) = try pagination(in: doc, pageURL: pageURL)
        return FASubmissionsPage(
            submissions: submissions,
            nextPageURL: next,
            previousPageURL: prev
        )
    }

    private static func parseFigure(_ figure: Element, pageURL: URL) throws -> FASubmission {
        let className = (try? figure.className()) ?? ""

        // <figure id="sid-66962680"> —— 新版是连字符（旧文档里写的 sid_ 已过时）
        var id: Int?
        if let rawID = try? figure.attr("id") {
            let digits = rawID.drop { !$0.isNumber }
            id = Int(digits)
        }

        // 缩略图：<b><u><a href="/view/123/"><img src="//t.furaffinity.net/..."></a></u></b>
        guard let img = try figure.select("b u a img").first() else {
            throw FAPageError.missingElement("figure b u a img")
        }
        guard let thumbnailURL = FAURLs.absoluteImageURL((try? img.attr("src")) ?? "") else {
            throw FAPageError.missingElement("img[src]")
        }

        guard let anchor = try figure.select("b u a").first(),
              let href = try? anchor.attr("href"),
              let submissionURL = FAURLs.resolve(href, relativeTo: pageURL) else {
            throw FAPageError.missingElement("figure b u a[href]")
        }

        if id == nil {
            // 从 /view/66962680/ 里抠出 id
            let digits = submissionURL.path.drop { !$0.isNumber }
            id = Int(digits)
        }
        guard let submissionID = id else {
            throw FAPageError.missingElement("figure id")
        }

        // 标题与作者：<figcaption><p><a>标题</a></p><p><i>by</i> <a>作者</a></p></figcaption>
        let captionLinks = try figure.select("figcaption p a")
        guard captionLinks.size() >= 2 else {
            throw FAPageError.missingElement("figcaption p a (expect 2, got \(captionLinks.size()))")
        }
        let titleAnchor = captionLinks.get(0)
        let authorAnchor = captionLinks.get(1)

        let title = (try? titleAnchor.text()) ?? ""
        let authorName = (try? authorAnchor.text()) ?? ""
        guard !authorName.isEmpty,
              let authorHref = try? authorAnchor.attr("href"),
              let authorURL = FAURLs.resolve(authorHref, relativeTo: pageURL) else {
            throw FAPageError.missingElement("author link")
        }

        let width = Double((try? img.attr("data-width")) ?? "") ?? 0
        let height = Double((try? img.attr("data-height")) ?? "") ?? 0

        return FASubmission(
            id: submissionID,
            url: submissionURL,
            title: title,
            authorName: authorName,
            authorURL: authorURL,
            thumbnailURL: thumbnailURL,
            thumbnailWidth: width,
            thumbnailHeight: height,
            rating: FASubmissionRating.from(className: className),
            kind: FASubmissionKind.from(className: className),
            rawTags: (try? img.attr("data-tags")) ?? ""
        )
    }

    // MARK: - 分页
    //
    // 实测（2026-11-07）：分页不是链接，而是一个 `method="GET"` 的 <form>，
    // 里面全是 hidden input（cat/atype/species/rating_*/per_page/page），按钮文本是 Next / Prev。
    // 所以要「读 form → 重建 query」，不能取 href（根本没有 href）。
    //
    // 坑：搜索页的 `page` 不是 hidden input，而是 <select>，真正的目标页在**按钮自己的属性**上
    // （`<button type="submit" name="page" value="2">Next</button>`）。
    // 只读 hidden 会重建出「还是第 1 页」的地址 → 翻页翻不动，表现为永远停在 48 条。
    private static func pagination(in doc: Document, pageURL: URL) throws -> (prev: URL?, next: URL?) {
        var prev: URL?
        var next: URL?

        let forms = try doc.select("form")
        for form in forms.array() {
            let buttons = (try? form.select("button"))?.array() ?? []
            for button in buttons {
                let label = ((try? button.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard label == "Next" || label == "Prev" else { continue }
                guard let url = url(fromForm: form, button: button, pageURL: pageURL) else { continue }
                if label == "Next" { next = url } else { prev = url }
            }
        }
        return (prev, next)
    }

    private static func url(fromForm form: Element, button: Element?, pageURL: URL) -> URL? {
        var items: [URLQueryItem]
        if let inputs = try? form.select("input"), let hidden = try? hiddenQueryItems(in: inputs) {
            items = hidden
        } else {
            items = []
        }

        // 按钮自身的 name/value 才是「点了这个按钮会提交什么」，优先级高于 hidden
        if let button {
            let name = (try? button.attr("name")) ?? ""
            let value = (try? button.attr("value")) ?? ""
            if !name.isEmpty {
                items.removeAll { $0.name == name }
                items.append(URLQueryItem(name: name, value: value))
            }
        }

        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = items
        components?.fragment = nil
        return components?.url
    }

    private static func hiddenQueryItems(in inputs: Elements) throws -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for input in inputs.array() {
            let type = (try? input.attr("type")) ?? ""
            guard type == "hidden" else { continue }
            let name = (try? input.attr("name")) ?? ""
            let value = (try? input.attr("value")) ?? ""
            guard !name.isEmpty else { continue }
            items.append(URLQueryItem(name: name, value: value))
        }
        return items
    }
}
