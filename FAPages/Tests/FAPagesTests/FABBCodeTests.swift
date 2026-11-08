import XCTest
@testable import FAPages

final class FABBCodeTests: XCTestCase {

    // MARK: - 真实样本

    /// 真机上扒下来的真实投稿（`/view/66961612/` 的下载文件，24KB）
    func testRealStoryParsesWithoutTagsLeft() throws {
        let text = try fixture("story-sample.txt")
        let blocks = FABBCode.parse(text)

        XCTAssertGreaterThan(blocks.count, 10, "一篇 350 行的故事不应该只解析出几块")

        // 标签必须被吃掉：正文里不该再出现 BBCode 的方括号标签
        let body = FABBCode.plainText(blocks)
        XCTAssertGreaterThan(body.count, 2000)
        for marker in ["[b]", "[/b]", "[center]", "[color=", "[h1]", "[/h1]"] {
            XCTAssertFalse(body.contains(marker), "残留标签 \(marker)")
        }

        // 这篇故事用了 [h1] 和 [color=#xxxxxx]，应当被识别出来
        let hasHeading = blocks.contains { if case .heading = $0 { return true } else { return false } }
        XCTAssertTrue(hasHeading)

        let colors = blocks.flatMap(\.runs).compactMap(\.colorHex)
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0.hasPrefix("#") && $0.count >= 4 })
    }

    // MARK: - 合成用例

    func testInlineStylesBecomeSeparateRuns() {
        let blocks = FABBCode.parse("[b]粗[/b]常[i]斜[/i]")
        XCTAssertEqual(blocks.count, 1)
        let runs = blocks[0].runs
        XCTAssertEqual(runs.map(\.text), ["粗", "常", "斜"])
        XCTAssertTrue(runs[0].bold)
        XCTAssertFalse(runs[1].bold)
        XCTAssertTrue(runs[2].italic)
    }

    func testAdjacentTagsCompose() {
        let runs = FABBCode.parse("[b][i][color=#c13d59]字[/color][/i][/b]")[0].runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].bold)
        XCTAssertTrue(runs[0].italic)
        XCTAssertEqual(runs[0].colorHex, "#c13d59")
    }

    func testBlankLineSeparatesBlocks() {
        let blocks = FABBCode.parse("第一段\n\n第二段")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].runs.map(\.text).joined(), "第一段")
        XCTAssertEqual(blocks[1].runs.map(\.text).joined(), "第二段")
    }

    func testSingleNewlineStaysInsideParagraph() {
        let blocks = FABBCode.parse("上\n下")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].runs.map(\.text).joined(), "上\n下")
    }

    func testHeadingIsItsOwnBlock() {
        let blocks = FABBCode.parse("开头\n\n[h1]标题[/h1]\n\n正文")
        XCTAssertEqual(blocks.count, 3)
        if case .heading(let level, let runs) = blocks[1] {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(runs.map(\.text).joined(), "标题")
        } else {
            XCTFail("第二个块应该是标题")
        }
    }

    func testListItems() {
        let blocks = FABBCode.parse("[ul]\n[*]一\n[*]二\n[/ul]")
        let items = blocks.compactMap { block -> String? in
            if case .listItem(let runs) = block { return runs.map(\.text).joined() }
            return nil
        }
        XCTAssertEqual(items, ["一", "二"])
    }

    func testQuoteAndRule() {
        let blocks = FABBCode.parse("[quote]引用[/quote]\n\n[hr]")
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true } else { return false } })
        XCTAssertTrue(blocks.contains { if case .rule = $0 { return true } else { return false } })
    }

    /// 作者手写标签，闭合错位是常态：不能因此吞掉正文
    func testUnclosedTagKeepsText() {
        let blocks = FABBCode.parse("[b]没有闭合的粗体\n\n下一段")
        let body = FABBCode.plainText(blocks)
        XCTAssertTrue(body.contains("没有闭合的粗体"))
        XCTAssertTrue(body.contains("下一段"))
        XCTAssertFalse(body.contains("[b]"))
    }

    func testUnknownTagsDroppedButTextKept() {
        let body = FABBCode.plainText(FABBCode.parse("[spoiler]剧透内容[/spoiler]"))
        XCTAssertEqual(body, "剧透内容")
    }

    func testMediaTagsRemoveTheirContent() {
        let body = FABBCode.plainText(FABBCode.parse("前[eicon]smile[/eicon]后"))
        XCTAssertEqual(body, "前后")
    }

    func testLinkKeepsURL() {
        let runs = FABBCode.parse("[url=https://example.com/x]示例[/url]")[0].runs
        XCTAssertEqual(runs[0].link?.absoluteString, "https://example.com/x")
        XCTAssertEqual(runs[0].text, "示例")
    }

    func testColorNamesAreTranslated() {
        XCTAssertEqual(FABBCode.parse("[color=red]x[/color]")[0].runs[0].colorHex, "#ff0000")
        XCTAssertNil(FABBCode.parse("[color=notacolor]x[/color]")[0].runs[0].colorHex)
    }

    func testBOMAndCRLF() {
        let blocks = FABBCode.parse("\u{FEFF}第一行\r\n\r\n第二段")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].runs.map(\.text).joined(), "第一行")
    }

    func testEmptyInput() {
        XCTAssertTrue(FABBCode.parse("").isEmpty)
        XCTAssertTrue(FABBCode.parse("\n\n\n").isEmpty)
    }

    // MARK: - 格式判断

    func testStoryFormatDetection() {
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.txt")!), .plainText)
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.MD")!), .markdown)
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.pdf")!), .pdf)
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.docx")!), .docx)
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.rtf")!), .rtf)
        XCTAssertEqual(FAStoryFormat.from(URL(string: "https://d.furaffinity.net/a.epub")!), .other("epub"))
        XCTAssertTrue(FAStoryFormat.plainText.isNativelyReadable)
        XCTAssertFalse(FAStoryFormat.pdf.isNativelyReadable)
    }

    // MARK: - 工具

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                                ?? Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
