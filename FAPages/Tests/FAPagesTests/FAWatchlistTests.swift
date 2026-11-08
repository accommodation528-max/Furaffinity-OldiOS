import XCTest
@testable import FAPages

final class FAWatchlistTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testWatchingList() throws {
        let html = try fixture("watchlist")
        let page = try FAWatchlist.parse(html, from: FAURLs.watching("nosense528"))

        XCTAssertTrue(page.title.contains("is watching"), "标题应表明这是「我关注的人」：\(page.title)")
        XCTAssertEqual(page.entries.count, 15)

        let first = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(first.slug, "amby")
        XCTAssertEqual(first.displayName, "amby")
        // URL 规范化会吃掉尾斜杠（和收藏/关注地址的测试同一个坑）
        XCTAssertEqual(first.url.path, "/user/amby")

        // 显示名保留用户原本的大小写，slug 是小写的
        let second = try XCTUnwrap(page.entries.dropFirst().first)
        XCTAssertEqual(second.slug, "biglovingwolf")
        XCTAssertEqual(second.displayName, "biglovingwolf")

        // 没有重复（页面上 `watch-list-items` 之间还夹着别的 div，容易重复计数）
        XCTAssertEqual(Set(page.entries.map { $0.slug }).count, page.entries.count)

        // 关注名单通常只有一页 —— 没有 Next 按钮时不该凭空造出下一页
        XCTAssertNil(page.nextPageURL)
    }

    func testWatchersListIsEmptyButValid() throws {
        let html = try fixture("watchers")
        let page = try FAWatchlist.parse(html, from: FAURLs.watchers("nosense528"))

        XCTAssertTrue(page.title.contains("watching"), page.title)
        XCTAssertTrue(page.entries.isEmpty, "没人关注这个账号时就是空名单，不是解析失败")
        XCTAssertTrue(page.isEmpty)
    }

    func testSlugParsing() {
        XCTAssertEqual(FAWatchlist.slug(from: "/user/amby/"), "amby")
        XCTAssertEqual(FAWatchlist.slug(from: "/user/spyro1mario"), "spyro1mario")
        XCTAssertNil(FAWatchlist.slug(from: "/gallery/amby/"))
        XCTAssertNil(FAWatchlist.slug(from: "/user/"))
    }
}
