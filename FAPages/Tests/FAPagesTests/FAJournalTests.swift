import XCTest
@testable import FAPages

final class FAJournalTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
                                "缺少 fixture \(name).html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRealJournal() throws {
        let url = URL(string: "https://www.furaffinity.net/journal/11447701/")!
        let journal = try FAJournals.parse(try fixture("journal"), from: url)

        XCTAssertEqual(journal.id, 11447701)
        XCTAssertEqual(journal.title, "2026 November Commissions [Closed]")
        XCTAssertEqual(journal.authorSlug, "glaucablitz")
        XCTAssertEqual(journal.authorName, "glaucablitz")
        XCTAssertNotNil(journal.authorAvatarURL)
        XCTAssertEqual(journal.authorAvatarURL?.host, "a.furaffinity.net")
        XCTAssertEqual(journal.postedAt?.timeIntervalSince1970, 1793192574)
        XCTAssertEqual(journal.rating, .general)
        XCTAssertTrue(journal.bodyText.contains("Commissions for this month"), journal.bodyText)
        XCTAssertTrue(journal.bodyText.contains("Trello"), "站外链接应该被还原成真实地址")
        XCTAssertFalse(journal.bodyText.contains("<"), "正文必须是纯文本")
        XCTAssertGreaterThan(journal.comments.count, 0, "这篇有历史评论")
    }

    func testBodyKeepsLineBreaks() throws {
        let url = URL(string: "https://www.furaffinity.net/journal/11447701/")!
        let journal = try FAJournals.parse(try fixture("journal"), from: url)
        // 正文里有 <br /> 排版，转文本后必须还是多行，不能拍成一行
        let lines = journal.bodyText.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 3, "正文被拍平成一行了：\(journal.bodyText.prefix(200))")
        XCTAssertFalse(journal.bodyText.contains("\n\n\n"), "空行应该被压成一个")
    }

    func testHTMLTextMinimal() {
        XCTAssertEqual(FAHTMLText.plain(html: "a<br/>b"), "a\nb")
        XCTAssertEqual(FAHTMLText.plain(html: "<div>x</div><div>y</div>"), "x\ny")
        XCTAssertEqual(FAHTMLText.plain(html: "<b>粗</b>体"), "粗体")
        XCTAssertEqual(FAHTMLText.plain(html: "<p>a</p><p></p><p>b</p>"), "a\nb")
    }
}
