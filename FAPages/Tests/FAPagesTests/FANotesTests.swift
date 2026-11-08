import XCTest
@testable import FAPages

final class FANotesTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
                                "缺少 fixture \(name).html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testInboxList() throws {
        let page = URL(string: "https://www.furaffinity.net/msg/pms/")!
        let notes = try FANotes.list(try fixture("notes-list"), from: page)

        XCTAssertGreaterThanOrEqual(notes.count, 3, "这页至少有 3 封私信")
        let first = try XCTUnwrap(notes.first)
        XCTAssertEqual(first.id, 141712666)
        XCTAssertEqual(first.subject, "Fur Affinity app update")
        XCTAssertEqual(first.authorName, "Ceylo")
        XCTAssertEqual(first.authorSlug, "ceylo")
        XCTAssertEqual(first.url.host, "www.furaffinity.net")
        XCTAssertTrue(first.url.path.hasPrefix("/msg/pms/"))
        XCTAssertFalse(first.isUnread)
        // 列表日期只有 title（"May 10, 2024 04:41AM"），要能退化成 Date
        XCTAssertNotNil(first.sentAt)
    }

    func testEmptyInbox() throws {
        let page = URL(string: "https://www.furaffinity.net/msg/pms/")!
        let html = try fixture("notes-inbox")
        let notes = try FANotes.list(html, from: page)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertTrue(FANotes.isEmptyList(html), "要能认出空收件箱，而不是把它当成解析失败")
    }

    func testUnreadFlag() throws {
        let page = URL(string: "https://www.furaffinity.net/msg/pms/")!
        let notes = try FANotes.list(try fixture("notes-unread"), from: page)
        let first = try XCTUnwrap(notes.first)
        XCTAssertTrue(first.isUnread, "这页第一封是未读")
    }

    func testComposeKey() throws {
        let key = FANotes.composeKey(try fixture("notes-inbox"))
        XCTAssertEqual(key?.count, 64, "CSRF key 是 64 位十六进制")
    }

    func testNoteThread() throws {
        let page = URL(string: "https://www.furaffinity.net/msg/pms/1/141712666/")!
        let note = try FANotes.note(try fixture("note-thread"), from: page)

        XCTAssertEqual(note.subject, "Re: hello there")
        XCTAssertEqual(note.authorSlug, "nosense528")
        XCTAssertEqual(note.authorName, "nosense528")
        XCTAssertEqual(note.sentAt?.timeIntervalSince1970, 1794000000)
        XCTAssertTrue(note.bodyText.contains("First line of the note"))
        XCTAssertTrue(note.bodyText.contains("\n"), "正文要保留换行")
        XCTAssertTrue(note.bodyText.contains("https://example.com/x"), "站外链接要还原成真实地址")
        XCTAssertEqual(note.replyKey?.count, 64)
    }

    /// 失败有两种形态：`notice-message` 和 `System Error`。
    /// 这个 fixture 是 2026-11-08 真机发信（收信人填自己）拿到的真实结果页：
    /// 只有 `<title>System Error</title>` + `<h2>System Error</h2>`，
    /// 完全没有 `section.notice-message` —— 只认后者会把失败当成功。
    func testSystemErrorMessage() throws {
        let html = try fixture("note-system-error")
        let message = FANotes.noticeMessage(html)

        XCTAssertNotNil(message, "System Error 页面必须被识别成提示，否则会假成功")
        XCTAssertTrue(message?.contains("cannot send notes to yourself") == true,
                      "实际提示：\(message ?? "nil")")
        XCTAssertFalse(message?.contains("Click here to go back") == true,
                       "按钮文字不该混进提示")
    }
}
