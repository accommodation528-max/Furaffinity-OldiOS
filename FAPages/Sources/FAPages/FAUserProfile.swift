import Foundation
import SwiftSoup

/// 用户主页（`/user/{name}/`）。
///
/// 注意页面用的是**自定义标签**（`<userpage-nav-header>` 等），不是 class ——
/// SwiftSoup 会把它们当普通元素，选择器照样能用。
public struct FAUserProfile: Sendable {

    public let slug: String            // URL 里的名字（大小写敏感）
    public let url: URL
    public let displayName: String
    public let avatarURL: URL?
    public let registeredAt: Date?
    /// 「Watched by N」
    public let watchersCount: Int?
    /// 关注按钮：不在关注状态是 "Watch"，已关注是 "-Watch"
    public let watchButtonText: String
    public let watchURL: URL?
    /// 主页里的分页导航：Home / Gallery / Scraps / Favs / Journals
    public let navLinks: [(title: String, url: URL)]

    public init(slug: String, url: URL, displayName: String, avatarURL: URL?,
                registeredAt: Date?, watchersCount: Int?, watchButtonText: String,
                watchURL: URL?, navLinks: [(title: String, url: URL)]) {
        self.slug = slug
        self.url = url
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.registeredAt = registeredAt
        self.watchersCount = watchersCount
        self.watchButtonText = watchButtonText
        self.watchURL = watchURL
        self.navLinks = navLinks
    }

    public var isWatching: Bool {
        watchButtonText.hasPrefix("-") || watchButtonText.lowercased().contains("unwatch")
    }

    /// 主页里「Gallery」那一栏的地址（找不到就按约定拼）
    public var galleryURL: URL {
        navLinks.first { $0.title.lowercased() == "gallery" }?.url ?? FAURLs.gallery(slug)
    }

    public static func parse(_ html: String, from pageURL: URL) throws -> FAUserProfile {
        try FAPageGuard.check(html)

        let doc: Document
        do {
            doc = try SwiftSoup.parse(html, pageURL.absoluteString)
        } catch {
            throw FAPageError.malformedHTML(String(describing: error))
        }

        // 显示名与 slug：<a class="c-usernameBlock__displayName" href="/user/x/">…</a>
        let displayAnchor = try? doc.select("a.c-usernameBlock__displayName").first()
        let displayHref = (try? displayAnchor?.attr("href")) ?? ""
        let resolvedUserURL = FAURLs.resolve(displayHref, relativeTo: pageURL) ?? pageURL
        let slug = resolvedUserURL.pathComponents.last(where: { $0 != "/" })
            ?? pageURL.pathComponents.last(where: { $0 != "/" })
            ?? ""

        var displayName = ((try? displayAnchor?.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty {
            displayName = ((try? doc.select("span.js-displayName").first()?.text()) ?? slug)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let avatarSrc = (try? doc.select("userpage-nav-avatar img").first()?.attr("src"))
            ?? (try? doc.select("img.avatar").first()?.attr("src"))
        let avatarURL = FAURLs.absoluteImageURL(avatarSrc ?? "")

        var registeredAt: Date?
        if let raw = try? doc.select("span.user-title span.popup_date[data-time]").first()?.attr("data-time"),
           let seconds = TimeInterval(raw) {
            registeredAt = Date(timeIntervalSince1970: seconds)
        }

        // 「Watched by 1」散在正文里，直接扫全文
        var watchersCount: Int?
        let pageText = (try? doc.text()) ?? ""
        if let match = Self.watchedByRegex.firstMatch(
            in: pageText, options: [], range: NSRange(pageText.startIndex..., in: pageText)
        ), let range = Range(match.range(at: 1), in: pageText) {
            watchersCount = Int(pageText[range].replacingOccurrences(of: ",", with: ""))
        }

        let watchAnchor = try? doc.select("a#watch-button").first()
        let watchButtonText = ((try? watchAnchor?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let watchURL = FAURLs.resolve((try? watchAnchor?.attr("href")) ?? "", relativeTo: pageURL)

        var navLinks: [(String, URL)] = []
        for anchor in (try? doc.select("ul.user-nav-page-links a").array()) ?? [] {
            let title = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  let url = FAURLs.resolve((try? anchor.attr("href")) ?? "", relativeTo: pageURL) else { continue }
            navLinks.append((title, url))
        }

        return FAUserProfile(
            slug: slug,
            url: resolvedUserURL,
            displayName: displayName.isEmpty ? slug : displayName,
            avatarURL: avatarURL,
            registeredAt: registeredAt,
            watchersCount: watchersCount,
            watchButtonText: watchButtonText,
            watchURL: watchURL,
            navLinks: navLinks
        )
    }

    private static let watchedByRegex = try! NSRegularExpression(
        pattern: "Watched by ([0-9][0-9,]*)", options: [.caseInsensitive]
    )
}
