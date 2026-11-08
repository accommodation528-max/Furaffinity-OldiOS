import Foundation
import SwiftSoup

/// 私信列表里的一行（`/msg/pms/` 左栏）。
public struct FANoteSummary: Sendable, Identifiable {
    public let id: Int
    public let url: URL
    public let subject: String
    public let authorName: String
    public let authorSlug: String
    public let sentAt: Date?
    /// 未读（列表里 `a.notelink` 带 `note-unread` class）
    public let isUnread: Bool
}

/// 一封打开后的私信（`/msg/pms/…`）。
public struct FANote: Sendable {
    public let subject: String
    public let authorName: String
    public let authorSlug: String
    public let sentAt: Date?
    /// 正文纯文本（保留换行）
    public let bodyText: String
    /// 回复表单里的 CSRF key —— 没有它 POST 会被拒
    public let replyKey: String?
}

public enum FANotes {

    // MARK: - 列表

    /// 从 `/msg/pms/` 页面解析左栏的私信列表。
    ///
    /// 结构：
    ///
    ///     div#notes-list
    ///       div.c-noteListItem
    ///         div.note-list-container
    ///           div.note-list-subjectgroup
    ///             div.note-list-checkbox input[value]   ← 私信 id
    ///             a.notelink[href=/msg/pms/1/<id>/#message]  （未读时带 note-unread）
    ///               div.c-noteListItem__subject            ← 标题
    ///           div.note-list-sendgroup
    ///             a.c-usernameBlock__displayName[href=/user/<slug>/]
    ///             div.note-list-senddate span.popup_date
    public static func list(_ html: String, from pageURL: URL) throws -> [FANoteSummary] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw FAPageError.malformedHTML(String(describing: error)) }

        let nodes = (try? doc.select("#notes-list div.c-noteListItem"))?.array() ?? []
        var notes: [FANoteSummary] = []

        for node in nodes {
            guard let link = try? node.select("a.notelink").first() else { continue }
            let href = (try? link.attr("href")) ?? ""
            let rawID = (try? node.select("div.note-list-checkbox input").first()?.attr("value")) ?? ""
            guard let url = FAURLs.resolve(href, relativeTo: pageURL),
                  let id = Int(rawID) ?? Self.idFromNoteURL(url)
            else { continue }

            let subject = ((try? node.select("div.c-noteListItem__subject").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var authorName = ""
            var authorSlug = ""
            if let authorNode = try? node.select("a.c-usernameBlock__displayName").first() {
                authorName = ((try? authorNode.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let authorHref = try? authorNode.attr("href") {
                    authorSlug = authorHref.split(separator: "/").last.map(String.init) ?? ""
                }
            }
            if authorName.isEmpty, let deleted = try? node.select("span.user-name-deleted").first()?.text() {
                authorName = deleted.isEmpty ? "[已注销用户]" : deleted
            }

            var sentAt: Date?
            if let popup = try? node.select("div.note-list-senddate span.popup_date").first() {
                if let raw = try? popup.attr("data-time"), let seconds = TimeInterval(raw), seconds > 0 {
                    sentAt = Date(timeIntervalSince1970: seconds)
                } else if let title = try? popup.attr("title"), !title.isEmpty {
                    // 退路：title 形如 "May 10, 2024 04:41AM"
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "MMM d, yyyy hh:mma"
                    sentAt = f.date(from: title)
                }
            }

            let unread = (try? link.hasClass("note-unread")) ?? false
            notes.append(FANoteSummary(id: id, url: url, subject: subject, authorName: authorName,
                                       authorSlug: authorSlug, sentAt: sentAt, isUnread: unread))
        }
        return notes
    }

    /// 列表里一条都没有 —— 用来区分「空收件箱」和「解析失败」
    public static func isEmptyList(_ html: String) -> Bool {
        html.contains("There are no notes to display")
    }

    // MARK: - 单封

    /// 解析一封打开的私信。
    ///
    ///     section#message
    ///       div.section-header h2                          ← 标题
    ///       div.message-center-note-information
    ///         div.addresses div.c-usernameBlock a.c-usernameBlock__displayName
    ///         span.popup_date
    ///       div.section-body > div.user-submitted-links     ← 正文
    ///     form#note-form input[name=key]                    ← 回复用的 CSRF key
    public static func note(_ html: String, from pageURL: URL) throws -> FANote {
        try FAPageGuard.check(html)

        let doc: Document
        do { doc = try SwiftSoup.parse(html) }
        catch { throw FAPageError.malformedHTML(String(describing: error)) }

        guard let section = try? doc.select("section#message").first() else {
            throw FAPageError.missingElement("section#message（私信正文）")
        }

        let subject = ((try? section.select("div.section-header h2").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var authorName = ""
        var authorSlug = ""
        let authorNodes = (try? section.select("div.addresses a.c-usernameBlock__displayName"))?.array() ?? []
        if let authorNode = authorNodes.first {
            authorName = ((try? authorNode.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = try? authorNode.attr("href") {
                authorSlug = href.split(separator: "/").last.map(String.init) ?? ""
            }
        }

        var sentAt: Date?
        if let popup = try? section.select("div.addresses span.popup_date").first(),
           let raw = try? popup.attr("data-time"), let seconds = TimeInterval(raw), seconds > 0 {
            sentAt = Date(timeIntervalSince1970: seconds)
        }

        var bodyText = ""
        if let body = try? section.select("div.section-body > div.user-submitted-links").first() {
            bodyText = FAHTMLText.plain(body)
        }
        if bodyText.isEmpty {
            bodyText = ((try? section.select("div.section-body").first()?.text()) ?? "")
        }

        let key = (try? doc.select("form#note-form input[name=key]").first()?.attr("value")) ?? ""

        guard !subject.isEmpty || !bodyText.isEmpty else {
            throw FAPageError.missingElement("私信内容")
        }

        return FANote(subject: subject, authorName: authorName, authorSlug: authorSlug,
                      sentAt: sentAt, bodyText: bodyText, replyKey: key.isEmpty ? nil : key)
    }

    // MARK: - 发信

    /// 发信 / 回信页里的 CSRF key（`form#note-form` 的 hidden `key`）。
    ///
    /// FA 的表单要先 GET 一次拿 key，POST 才认 —— 不带 key 会直接被踢回表单页。
    public static func composeKey(_ html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html),
              let value = try? doc.select("form#note-form input[name=key]").first()?.attr("value"),
              !value.isEmpty else { return nil }
        return value
    }

    /// 发信页里有没有 Cloudflare Turnstile 人机校验。
    ///
    /// 实测（2026-11-08）：`/newpm/{user}/` 的表单带 `<div class="cf-turnstile" data-sitekey="…">`，
    /// 直接 URLSession POST `/msg/send/` 会拿到
    /// `Error sending a note. CAPTCHA verification failed.` —— 也就是说
    /// **发私信必须在真实 WebView 里过 Turnstile**，纯 HTTP 提交是不可能的。
    public static func requiresCaptcha(_ html: String) -> Bool {
        html.contains("cf-turnstile") || html.contains("challenges.cloudflare.com/turnstile")
    }

    /// POST 之后 FA 给的系统提示。
    ///
    /// 实测（2026-11-08）有两种完全不同的失败形态，**只认其中一种会把失败当成功**：
    /// - `section.notice-message div.redirect-message` —— 「Error sending a note. CAPTCHA verification failed.」
    /// - `section .section-header h2 = System Error` + `section-body` —— 「You cannot send notes to yourself」
    ///   （页面 710B，`<title>System Error</title>`，没有任何 notice-message）
    ///
    /// 成功时这两种都不出现（直接回到私信列表），所以返回 nil ＝ 看起来成功。
    public static func noticeMessage(_ html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }

        if let node = try? doc.select("section.notice-message div.redirect-message").first(),
           let text = try? node.text() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // System Error / System Message 形态：标题在 h2，正文在 section-body
        // （正文尾部会跟一个「Click here to go back」按钮，要剔掉）
        for section in (try? doc.select("section").array()) ?? [] {
            guard let heading = try? section.select("div.section-header h2").first()?.text(),
                  heading.contains("System Error") || heading.contains("System Message")
            else { continue }

            var body = (try? section.select("div.section-body").first()?.text())
                ?? (try? section.text()) ?? ""
            if let range = body.range(of: "Click here to go back") {
                body = String(body[..<range.lowerBound])
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return "\(heading)：\(trimmed)" }
        }
        return nil
    }

    private static func idFromNoteURL(_ url: URL) -> Int? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.last.flatMap { Int($0) }
    }
}
