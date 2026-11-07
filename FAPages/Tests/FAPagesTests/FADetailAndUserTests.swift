import XCTest
@testable import FAPages

/// 详情页与用户页的解析测试（Linux 上跑，fixture 是真实页面）。
final class FADetailAndUserTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") else {
            XCTFail("找不到 fixture: \(name).html")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 未登录看到的空壳页

    /// 成人内容对未登录访客会返回一张 `Login Required` 普通页（状态码 200），
    /// 解析器必须把它认成 `.loginRequired`，而不是报「缺少元素」。
    func testLoginRequiredPageFromRealFixture() throws {
        let html = try fixture("login-required")
        XCTAssertTrue(FAPageGuard.isLoginRequired(html))

        XCTAssertThrowsError(try FASubmissionDetail.parse(html, from: FAURLs.submission(66962944))) { error in
            guard case FAPageError.loginRequired = error else {
                return XCTFail("期望 .loginRequired，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try FASubmissionsPage.parse(html, from: FAURLs.submission(66962944))) { error in
            guard case FAPageError.loginRequired = error else {
                return XCTFail("期望 .loginRequired，实际 \(error)")
            }
        }
    }

    /// 普通页面不能被误判成登录页
    func testNormalPagesAreNotFlaggedAsLoginRequired() throws {
        XCTAssertFalse(FAPageGuard.isLoginRequired(try fixture("submission")))
        XCTAssertFalse(FAPageGuard.isLoginRequired(try fixture("user")))
        XCTAssertFalse(FAPageGuard.isLoginRequired(try fixture("browse")))
    }

    // MARK: - 投稿详情

    private func detail() throws -> FASubmissionDetail {
        try FASubmissionDetail.parse(try fixture("submission"), from: FAURLs.submission(66962680))
    }

    func testDetailBasics() throws {
        let d = try detail()
        XCTAssertEqual(d.id, 66962680)
        XCTAssertEqual(d.title, "Sunburn")
        XCTAssertEqual(d.authorName, "Spyro1mario")
        XCTAssertEqual(d.authorSlug, "spyro1mario")
        XCTAssertEqual(d.authorURL.absoluteString, "https://www.furaffinity.net/user/spyro1mario/")
        XCTAssertEqual(d.kind, .image)
        XCTAssertEqual(d.rating, .general)
    }

    func testDetailImages() throws {
        let d = try detail()
        let full = try XCTUnwrap(d.fullviewURL, "详情页必须有原图（data-fullview-src）")
        XCTAssertEqual(full.host, "d.furaffinity.net")
        XCTAssertTrue(full.absoluteString.hasSuffix("1794055731.spyro1mario_sunburn.png"))
        XCTAssertEqual(full.scheme, "https")

        let preview = try XCTUnwrap(d.previewURL)
        XCTAssertEqual(preview.host, "t.furaffinity.net")
        XCTAssertTrue(preview.absoluteString.contains("@600"), "600 宽预览")
    }

    func testDetailAvatarAndDate() throws {
        let d = try detail()
        XCTAssertEqual(d.authorAvatarURL?.host, "a.furaffinity.net")
        XCTAssertEqual(try XCTUnwrap(d.postedAt).timeIntervalSince1970, 1794055731, accuracy: 0.5)
    }

    func testDetailTags() throws {
        let d = try detail()
        XCTAssertTrue(d.tags.contains("male"), "tags=\(d.tags)")
        XCTAssertTrue(d.tags.contains("skylanders"), "tags=\(d.tags)")
        // 标签块里每个标签有一个空 tag-block 按钮 + 一个真链接，不能重复
        XCTAssertEqual(d.tags.count, Set(d.tags.map { $0.lowercased() }).count)
    }

    func testDetailStats() throws {
        let d = try detail()
        XCTAssertEqual(d.views, 8)
        XCTAssertEqual(d.commentCount, 0)
        XCTAssertEqual(d.favoriteCount, 0)
        XCTAssertEqual(d.attributes.first?.0, "Category")
        XCTAssertTrue(d.attributes.contains { $0.0 == "Resolution" }, "attributes=\(d.attributes)")
    }

    func testDetailDescriptionAndDownload() throws {
        let d = try detail()
        XCTAssertEqual(d.descriptionText, "Skylanders")
        XCTAssertEqual(d.downloadURL?.host, "d.furaffinity.net")
    }

    // MARK: - 用户页

    private func user() throws -> FAUserProfile {
        try FAUserProfile.parse(try fixture("user"), from: FAURLs.user("spyro1mario"))
    }

    func testUserBasics() throws {
        let u = try user()
        XCTAssertEqual(u.slug, "spyro1mario")
        XCTAssertEqual(u.displayName, "Spyro1mario")
        XCTAssertEqual(u.url.absoluteString, "https://www.furaffinity.net/user/spyro1mario/")
        XCTAssertEqual(u.avatarURL?.host, "a.furaffinity.net")
    }

    func testUserRegistration() throws {
        let u = try user()
        XCTAssertEqual(try XCTUnwrap(u.registeredAt).timeIntervalSince1970, 1773331699, accuracy: 0.5)
    }

    func testUserNavLinks() throws {
        let u = try user()
        XCTAssertTrue(u.navLinks.count >= 4, "navLinks=\(u.navLinks.map { $0.title })")
        let gallery = u.navLinks.first { $0.title.lowercased() == "gallery" }
        XCTAssertEqual(try XCTUnwrap(gallery).url.absoluteString, "https://www.furaffinity.net/gallery/spyro1mario/")
        XCTAssertEqual(u.galleryURL, try XCTUnwrap(gallery).url)
    }

    func testUserWatchButton() throws {
        let u = try user()
        XCTAssertEqual(u.watchButtonText, "Watch")
        XCTAssertFalse(u.isWatching)
        XCTAssertEqual(try XCTUnwrap(u.watchURL).path.hasPrefix("/watch/spyro1mario"), true)
    }
}
