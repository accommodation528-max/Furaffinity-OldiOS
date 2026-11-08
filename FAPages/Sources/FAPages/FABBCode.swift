import Foundation

/// 一段样式一致的文字。
///
/// FA 的文本投稿下载下来是 **BBCode**（`[b]`、`[color=#c13d59]`、`[h1]`……），
/// 不是纯文本 —— 直接当纯文本显示的话，满屏都是方括号标签。
public struct FAStyledRun: Equatable, Sendable {

    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    /// `#rrggbb` 或 `#rgb`；FA 的 `[color=red]` 这类颜色名我们也能翻译
    public var colorHex: String?
    public var isSuperscript: Bool
    public var isSubscript: Bool
    public var link: URL?

    public init(
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        colorHex: String? = nil,
        isSuperscript: Bool = false,
        isSubscript: Bool = false,
        link: URL? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.colorHex = colorHex
        self.isSuperscript = isSuperscript
        self.isSubscript = isSubscript
        self.link = link
    }
}

/// 阅读器的一块内容。
public enum FAStoryBlock: Equatable, Sendable {
    case heading(level: Int, runs: [FAStyledRun])
    case paragraph(runs: [FAStyledRun])
    case quote(runs: [FAStyledRun])
    case listItem(runs: [FAStyledRun])
    case rule

    public var runs: [FAStyledRun] {
        switch self {
        case .heading(_, let runs), .paragraph(let runs), .quote(let runs), .listItem(let runs):
            return runs
        case .rule:
            return []
        }
    }
}

/// BBCode → 结构化文本。
///
/// 设计原则是**宽容**：FA 上的作者手写标签，闭合错位、标签拼错、自造标签都很常见。
/// 解析器宁可多显示一点正文，也不能因为一个 `[color` 让整篇变成乱码。
public enum FABBCode {

    // MARK: - 入口

    public static func parse(_ raw: String) -> [FAStoryBlock] {
        var parser = Parser(raw)
        return parser.run()
    }

    /// 给「复制正文」用：不带任何样式
    public static func plainText(_ blocks: [FAStoryBlock]) -> String {
        blocks.map { block in
            let text = block.runs.map(\.text).joined()
            switch block {
            case .heading, .paragraph, .quote, .listItem:
                return text
            case .rule:
                return "———"
            }
        }.joined(separator: "\n\n")
    }

    /// 估算篇幅（阅读进度、阅读时长用）
    public static func characterCount(_ blocks: [FAStoryBlock]) -> Int {
        blocks.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.count } }
    }
}

// MARK: - 解析器

private struct Parser {

    private enum BlockKind {
        case paragraph
        case heading(Int)
        case quote
        case listItem
    }

    private struct Tag {
        var name: String
        var value: String?
    }

    private let source: String
    private var index: String.Index

    private var blocks: [FAStoryBlock] = []
    private var runs: [FAStyledRun] = []
    private var buffer = ""
    private var stack: [Tag] = []
    private var blockKind: BlockKind = .paragraph

    init(_ raw: String) {
        // BOM 与 CRLF：`story.txt` 实测就是 UTF-8 BOM + CRLF
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        source = text
        index = text.startIndex
    }

    mutating func run() -> [FAStoryBlock] {
        while index < source.endIndex {
            let ch = source[index]
            if ch == "[" {
                if consumeTag() { continue }
            }
            if ch == "\n" {
                if isSuppressing {
                    index = source.index(after: index)
                    continue
                }
                handleNewline()
                continue
            }
            if isSuppressing {
                index = source.index(after: index)
                continue
            }
            buffer.append(ch)
            index = source.index(after: index)
        }
        flushBlock()
        return blocks
    }

    // MARK: 标签

    /// 返回 true 表示确实吃掉了 `[...]`
    private mutating func consumeTag() -> Bool {
        let start = index
        guard let close = source[index...].firstIndex(of: "]") else { return false }

        let inner = String(source[source.index(after: index)..<close])
        // `[img]http://...[/img]` 里的 `[` 不是标签；`[` 后面紧跟非字母基本可以当正文
        guard let first = inner.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "/" || first == "*" else {
            return false
        }

        index = source.index(after: close)
        apply(inner)
        _ = start
        return true
    }

    private mutating func apply(_ raw: String) {
        // 样式要在这里换：先把「已经攒着、还带着旧样式」的文字落成 run，
        // 否则 `[b]粗字之后` 会把整个缓冲区都涂成粗体。
        flushBuffer()

        var body = raw
        var closing = false
        if body.hasPrefix("/") {
            closing = true
            body.removeFirst()
        }

        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map { String($0).lowercased().trimmingCharacters(in: .whitespaces) } ?? ""
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil

        if closing {
            closeTag(name)
        } else {
            openTag(name, value: value)
        }
    }

    private mutating func openTag(_ name: String, value: String?) {
        switch name {
        case "h1", "h2", "h3":
            flushBlock()
            blockKind = .heading(Int(name.dropFirst()) ?? 1)
            stack.append(Tag(name: name, value: value))

        case "quote":
            flushBlock()
            blockKind = .quote
            stack.append(Tag(name: name, value: value))

        case "ul", "ol":
            flushBlock()
            stack.append(Tag(name: name, value: value))

        case "*", "li":
            flushBlock()
            blockKind = .listItem

        case "hr":
            flushBlock()
            blocks.append(.rule)

        // 这些标签里是「不该显示的东西」（表情、图片、用户名图标）
        case "eicon", "icon", "img", "user":
            stack.append(Tag(name: name, value: value))

        case "url":
            stack.append(Tag(name: name, value: value))

        case "b", "strong", "i", "em", "u", "s", "strike", "sub", "sup", "color", "size":
            stack.append(Tag(name: name, value: value))

        default:
            // 不认识的标签：丢掉标签、保留内容
            break
        }
    }

    private mutating func closeTag(_ name: String) {
        switch name {
        case "h1", "h2", "h3", "quote", "ul", "ol", "list", "*", "li":
            flushBlock()
            blockKind = .paragraph
            while let last = stack.last, isBlockTag(last.name) { stack.removeLast() }

        default:
            // 从栈顶往下找第一个同名标签弹掉；找不到就当做没这回事（宽容）
            if let position = stack.lastIndex(where: { $0.name == name }) {
                stack.removeSubrange(position...)
            }
        }
    }

    private func isBlockTag(_ name: String) -> Bool {
        ["h1", "h2", "h3", "quote", "ul", "ol", "list"].contains(name)
    }

    /// `[eicon]`/`[img]`/`[user]` 里的内容是「附件」而不是正文（表情名、图片地址、用户名图标）
    private var isSuppressing: Bool {
        stack.contains { ["eicon", "icon", "img", "user"].contains($0.name) }
    }

    // MARK: 文本

    private mutating func handleNewline() {
        // 行尾空白没有意义
        while buffer.last == " " { buffer.removeLast() }

        index = source.index(after: index)          // 吃掉这个换行

        if index < source.endIndex, source[index] == "\n" {
            // 空行 = 段落结束；连续的多个空行只算一次
            flushBlock()
            while index < source.endIndex, source[index] == "\n" {
                index = source.index(after: index)
            }
        } else {
            // 单换行 = 段内换行
            buffer.append("\n")
        }
    }

    private mutating func flushBuffer() {
        guard !buffer.isEmpty else { return }
        runs.append(makeRun(buffer))
        buffer = ""
    }

    private mutating func flushBlock() {
        // 缓冲区里剩的可能只是换行；但已经落成 run 的文字（样式切换过）不能丢
        if !buffer.isEmpty {
            let trimmed = buffer.trimmingCharacters(in: .newlines)
            if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                runs.append(makeRun(trimmed))
            }
            buffer = ""
        }

        guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            runs = []
            return
        }

        runs = Self.trimBlockEdges(runs)

        let built: FAStoryBlock
        switch blockKind {
        case .paragraph: built = .paragraph(runs: runs)
        case .heading(let level): built = .heading(level: level, runs: runs)
        case .quote: built = .quote(runs: runs)
        case .listItem: built = .listItem(runs: runs)
        }
        blocks.append(built)
        runs = []
    }

    /// 去掉块首尾的空 run 与首尾换行；块内的换行要留着（作者靠它排版）
    static func trimBlockEdges(_ runs: [FAStyledRun]) -> [FAStyledRun] {
        var copy = runs
        while let first = copy.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.removeFirst()
        }
        while let last = copy.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.removeLast()
        }
        guard !copy.isEmpty else { return copy }

        copy[0].text = String(copy[0].text.drop(while: { $0 == "\n" }))
        let last = copy.count - 1
        copy[last].text = String(String(copy[last].text.reversed().drop(while: { $0 == "\n" }).reversed()))
        return copy
    }

    private func makeRun(_ text: String) -> FAStyledRun {        var run = FAStyledRun(text: text)
        for tag in stack {
            switch tag.name {
            case "b", "strong": run.bold = true
            case "i", "em": run.italic = true
            case "u": run.underline = true
            case "s", "strike": run.strikethrough = true
            case "sub": run.isSubscript = true
            case "sup": run.isSuperscript = true
            case "color": run.colorHex = Self.normalizeColor(tag.value)
            case "url": run.link = tag.value.flatMap { URL(string: $0) }
            default: break
            }
        }
        return run
    }

    static func normalizeColor(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
            let hex = value.lowercased()
            guard hex.count == 3 || hex.count == 6,
                  hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            return "#" + hex
        }
        // FA 作者常用的颜色名
        let named: [String: String] = [
            "red": "#ff0000", "green": "#008000", "blue": "#0000ff",
            "orange": "#ffa500", "purple": "#800080", "pink": "#ffc0cb",
            "yellow": "#ffff00", "white": "#ffffff", "black": "#000000",
            "gray": "#808080", "grey": "#808080", "cyan": "#00ffff",
            "magenta": "#ff00ff", "brown": "#a52a2a", "gold": "#ffd700",
        ]
        return named[value.lowercased()]
    }
}
