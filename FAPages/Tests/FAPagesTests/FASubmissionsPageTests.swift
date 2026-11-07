import XCTest
@testable import FAPages

/// 这些测试跑在 **Linux 上**（`swift test`），不依赖 iOS / 网络 / 手机。
/// fixture 是 2026-11-07 抓下来的真实页面，FA 改版时它们会先红——这正是我们要的早期预警。
final class FASubmissionsPageTests: XCTestCase {

    // MARK: - 辅助

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") else {
            XCTFail("找不到 fixture: \(name).html")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func browsePage() throws -> FASubmissionsPage {
        try FASubmissionsPage.parse(try fixture("browse"), from: FAURLs.browse)
    }

    // MARK: - 浏览页

    func testBrowsePageParsesAllFigures() throws {
        let page = try browsePage()
        XCTAssertEqual(page.submissions.count, 48, "浏览页每页固定 48 条")
    }

    func testFirstSubmissionFields() throws {
        let page = try browsePage()
        let first = try XCTUnwrap(page.submissions.first)

        XCTAssertEqual(first.id, 66962680)
        XCTAssertEqual(first.title, "Sunburn")
        XCTAssertEqual(first.authorName, "Spyro1mario")
        XCTAssertEqual(first.authorURL.absoluteString, "https://www.furaffinity.net/user/spyro1mario/")
        XCTAssertEqual(first.url.absoluteString, "https://www.furaffinity.net/view/66962680/")
        XCTAssertEqual(first.rating, .general)
        XCTAssertEqual(first.kind, .image)
    }

    func testThumbnailURLIsUpgradedToHTTPS() throws {
        let first = try XCTUnwrap(try browsePage().submissions.first)
        // 页面里是协议相对的 //t.furaffinity.net/...，必须补成 https
        XCTAssertEqual(first.thumbnailURL.scheme, "https")
        XCTAssertEqual(first.thumbnailURL.host, "t.furaffinity.net")
        XCTAssertTrue(first.thumbnailURL.absoluteString.contains("66962680@200"))
    }

    func testThumbnailDimensionsAreNumbers() throws {
        let first = try XCTUnwrap(try browsePage().submissions.first)
        XCTAssertGreaterThan(first.thumbnailWidth, 0)
        XCTAssertGreaterThan(first.thumbnailHeight, 0)
        XCTAssertGreaterThan(first.aspectRatio, 0)
    }

    func testEverySubmissionHasRequiredFields() throws {
        let page = try browsePage()
        for s in page.submissions {
            XCTAssertFalse(s.title.isEmpty, "id=\(s.id) 标题为空")
            XCTAssertFalse(s.authorName.isEmpty, "id=\(s.id) 作者为空")
            XCTAssertFalse(s.rawTags.isEmpty, "id=\(s.id) 标签为空")
            XCTAssertEqual(s.url.host, "www.furaffinity.net")
        }
    }

    func testIDsAreUnique() throws {
        let page = try browsePage()
        let ids = page.submissions.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "同一页出现重复投稿 id")
    }

    // MARK: - 分页（form 重建）

    func testNextPageURLIsRebuiltFromForm() throws {
        let page = try browsePage()
        let next = try XCTUnwrap(page.nextPageURL, "浏览页应有 Next")
        let comps = try XCTUnwrap(URLComponents(url: next, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(comps.path, "/browse/")
        XCTAssertEqual(items["page"], "2")
        XCTAssertEqual(items["per_page"], "48")
        XCTAssertEqual(items["rating_general"], "1")
    }

    func testFirstPageHasNoPrevious() throws {
        let page = try browsePage()
        XCTAssertNil(page.previousPageURL, "第一页不该有 Prev")
    }

    // MARK: - 类型分布

    /// 实测：浏览页默认只出图片（48/48）；首页才是混合的（图片 64 + 文章 24 + 音乐 24）
    func testBrowsePageIsAllImages() throws {
        let page = try browsePage()
        XCTAssertTrue(page.submissions.allSatisfy { $0.kind == .image }, "浏览页当前全部是 t-image")
    }

    func testHomePageKindDistribution() throws {
        let page = try FASubmissionsPage.parse(try fixture("home"), from: FAURLs.home)
        let counts = page.submissions.reduce(into: [FASubmissionKind: Int]()) { $0[$1.kind, default: 0] += 1 }
        XCTAssertEqual(counts[.image], 64)
        XCTAssertEqual(counts[.text], 24)
        XCTAssertEqual(counts[.audio], 24)
        XCTAssertNil(counts[.unknown], "不该有识别不出的类型")
    }

    func testOnlyGeneralRatingForGuest() throws {
        let page = try browsePage()
        XCTAssertTrue(page.submissions.allSatisfy { $0.rating == .general })
    }

    // MARK: - 首页（同一套 figure 结构）

    func testHomePageUsesSameParser() throws {
        let page = try FASubmissionsPage.parse(try fixture("home"), from: FAURLs.home)
        XCTAssertEqual(page.submissions.count, 112)
        XCTAssertFalse(page.submissions.isEmpty)
    }

    // MARK: - 搜索结果页

    func testSearchResultsPageUsesSameParser() throws {
        let url = FAURLs.search("dragon")
        let page = try FASubmissionsPage.parse(try fixture("search"), from: url)
        XCTAssertEqual(page.submissions.count, 48, "搜索结果每页 48 条")

        // 搜索页的 page 不是 hidden input，而是 <select> + 按钮自带 name/value，
        // 只读 hidden 会重建出「还是第 1 页」的地址（真机上的表现：永远停在 48 条）
        let next = try XCTUnwrap(page.nextPageURL, "搜索结果页有下一页")
        let comps = try XCTUnwrap(URLComponents(url: next, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(comps.path, "/search/")
        XCTAssertEqual(items["page"], "2", "目标页来自 Next 按钮的 value")

        // 搜索结果页比首页更杂：图片 + 小说 + 音乐混在一起
        let counts = page.submissions.reduce(into: [FASubmissionKind: Int]()) { $0[$1.kind, default: 0] += 1 }
        XCTAssertGreaterThan(counts[.image] ?? 0, 0)
        XCTAssertGreaterThan((counts[.text] ?? 0) + (counts[.audio] ?? 0), 0, "搜索结果里应该有小说或音乐")
        XCTAssertNil(counts[.unknown], "不该有识别不出的类型")
    }

    func testSearchURLShape() {
        let url = FAURLs.search("dragon", page: 2)
        XCTAssertEqual(url.absoluteString, "https://www.furaffinity.net/search/?q=dragon&page=2")
    }

    func testThumbnailVariantIsRewritable() throws {
        let first = try XCTUnwrap(try browsePage().submissions.first)
        let bigger = FAURLs.thumbnailSized(first.thumbnailURL, pixels: 400)
        XCTAssertTrue(bigger.absoluteString.contains("@400-"), "@200 应该被换成 @400")
        XCTAssertTrue(bigger.absoluteString.hasSuffix(".jpg"))
        // 没有档位标记的地址原样返回
        let plain = URL(string: "https://d.furaffinity.net/art/x/y.png")!
        XCTAssertEqual(FAURLs.thumbnailSized(plain).absoluteString, plain.absoluteString)
    }

    // MARK: - 容错

    func testEmptyHTMLYieldsEmptyPage() throws {
        let page = try FASubmissionsPage.parse("<html><body>nothing here</body></html>", from: FAURLs.browse)
        XCTAssertTrue(page.submissions.isEmpty)
        XCTAssertNil(page.nextPageURL)
    }

    func testGarbageFigureIsSkippedNotFatal() throws {
        // 一个缺 img 的 figure 不能让整页解析失败
        let html = """
        <html><body>
        <figure id="sid-1" class="r-general t-image">
          <b><u><a href="/view/1/"><img src="//t.furaffinity.net/1@200.jpg" data-width="1" data-height="1"></a></u></b>
          <figcaption><p><a href="/view/1/">T</a></p><p><i>by</i> <a href="/user/a/">A</a></p></figcaption>
        </figure>
        <figure id="sid-2" class="r-general t-image"><b><u><a href="/view/2/"></a></u></b></figure>
        </body></html>
        """
        let page = try FASubmissionsPage.parse(html, from: FAURLs.browse)
        XCTAssertEqual(page.submissions.count, 1)
        XCTAssertEqual(page.submissions.first?.id, 1)
    }
}
