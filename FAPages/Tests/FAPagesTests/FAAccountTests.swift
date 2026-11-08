import XCTest
@testable import FAPages

/// 账号相关的解析：收藏/关注按钮、评论、站内通知、关注流分页、我是谁。
/// 用到的 fixture 全部来自真实登录态页面（`detail-logged-in` / `journal` / `msg-others` / `msg-submissions`）。
final class FAAccountTests: XCTestCase {

    private func html(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") else {
            XCTFail("找不到 fixture: \(name).html")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 收藏 / 私信按钮

    func testLoggedInDetailExposesFavoriteAction() throws {
        let page = try html("detail-logged-in")
        let url = URL(string: "https://www.furaffinity.net/view/66962944/")!
        let detail = try FASubmissionDetail.parse(page, from: url)

        XCTAssertEqual(detail.id, 66962944)
        XCTAssertFalse(detail.isFavorited, "还没收藏时按钮文本是 +Fav")

        let favorite = try XCTUnwrap(detail.favoriteURL)
        XCTAssertEqual(favorite.path, "/fav/66962944", "收藏地址里带 key，必须原样使用")
        XCTAssertTrue(favorite.query?.contains("key=") ?? false, "缺了 key 服务端会拒绝")

        let note = try XCTUnwrap(detail.noteURL)
        XCTAssertEqual(note.path, "/newpm/krue")
    }

    func testGuestDetailHasNoFavoriteAction() throws {
        let page = try html("submission")   // 未登录抓的页面
        let url = URL(string: "https://www.furaffinity.net/view/66962680/")!
        let detail = try FASubmissionDetail.parse(page, from: url)

        XCTAssertNil(detail.favoriteURL, "未登录时 #submission-options 里没有收藏按钮")
        XCTAssertFalse(detail.isFavorited)
    }

    // MARK: - 评论

    func testCommentsParseWithAuthorsAndDates() throws {
        let page = try html("journal")
        let url = URL(string: "https://www.furaffinity.net/journal/11447701/")!
        let comments = try FAComments.parse(page, from: url)

        XCTAssertEqual(comments.count, 13)

        let first = try XCTUnwrap(comments.first)
        XCTAssertEqual(first.id, "61771922")
        XCTAssertEqual(first.authorSlug, "fib-the-blue-goblin")
        XCTAssertEqual(first.authorName, "Fib-the-Blue-Goblin")
        XCTAssertEqual(first.title, "Word Wizard!", "自定义标题只在 comment-title 里")
        XCTAssertTrue(first.body.contains("claim a slot"), "正文实际文本：\(first.body)")
        XCTAssertEqual(first.postedAt?.timeIntervalSince1970, 1793194429)
        XCTAssertEqual(first.depth, 0)
        XCTAssertEqual(first.avatarURL?.host, "a.furaffinity.net")

        // 第二条换个作者，确认不是把所有行都读成同一个人
        let second = try XCTUnwrap(comments.dropFirst().first)
        XCTAssertEqual(second.authorSlug, "glaucablitz")
    }

    func testCommentsAreFlatUnlessNested() throws {
        let page = try html("journal")
        let url = URL(string: "https://www.furaffinity.net/journal/11447701/")!
        let comments = try FAComments.parse(page, from: url)

        // 这 13 条是一层平铺（没有回复），深度必须全是 0
        XCTAssertTrue(comments.allSatisfy { $0.depth == 0 })
    }

    func testCommentsDisabledMarker() {
        XCTAssertTrue(FAComments.areCommentsDisabled(in: "<p>Comment posting has been disabled on this submission</p>"))
        XCTAssertFalse(FAComments.areCommentsDisabled(in: "<p>hello</p>"))
    }

    // MARK: - 站内通知

    func testNotificationRowsParse() throws {
        let page = try html("msg-others")
        let url = URL(string: "https://www.furaffinity.net/msg/others/")!
        let notifications = try FANotifications.parse(page, from: url)

        XCTAssertEqual(notifications.count, 5, "这个账号当前只有 5 条 journal 通知")

        let first = try XCTUnwrap(notifications.first)
        XCTAssertEqual(first.kind, .journal)
        XCTAssertEqual(first.sectionTitle, "Journals")
        XCTAssertEqual(first.id, "11447701", "id 来自勾选框的 value")
        XCTAssertTrue(first.title.contains("2026 November Commissions"))
        XCTAssertEqual(first.authorSlug, "glaucablitz")
        XCTAssertEqual(first.rating, .general)
        XCTAssertEqual(first.url?.path, "/journal/11447701")
        XCTAssertEqual(first.postedAt?.timeIntervalSince1970, 1793192574)
    }

    // MARK: - 关注流

    func testWatchFeedUsesCursorPagination() throws {
        let page = try html("msg-submissions")
        let url = URL(string: "https://www.furaffinity.net/msg/submissions/")!
        let parsed = try FASubmissionsPage.parse(page, from: url)

        XCTAssertEqual(parsed.submissions.count, 48, "关注流也是 48 个一页")

        // 关注流没有分页 form，只有 <a class="button standard more">Next 48</a>
        let next = try XCTUnwrap(parsed.nextPageURL, "必须从链接里取游标，否则翻不动")
        XCTAssertEqual(next.path, "/msg/submissions/new~66759279@48")
    }

    // MARK: - 我是谁

    func testAccountIdentityFromLoggedInPage() throws {
        let page = try html("detail-logged-in")
        let identity = try XCTUnwrap(FAAccount.parse(page, from: FAURLs.base))

        XCTAssertEqual(identity.displayName, "Nosense528")
        XCTAssertEqual(identity.slug, "nosense528")
    }

    func testGuestPageHasNoIdentity() throws {
        let page = try html("browse")
        XCTAssertNil(try FAAccount.parse(page, from: FAURLs.base))
    }
}
