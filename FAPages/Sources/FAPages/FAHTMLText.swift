import Foundation
import SwiftSoup

/// HTML → 纯文本，**保留换行**。
///
/// 为什么不直接用 `Element.text()`：它把整棵树拍平成一长串，`<br>` 全部丢失。
/// 对投稿描述还能看（描述本来就是几句散文），但 Journal 的内容是列表式的
/// （「1) 某人 2) 某人」这种），一行行粘在一起就没法读了。
public enum FAHTMLText {

    /// 块级元素：前后各断一行
    private static let blockTags: Set<String> = [
        "div", "p", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "tr", "table", "section", "article", "pre", "figure"
    ]

    public static func plain(_ element: Element) -> String {
        var raw = ""
        render(node: element, into: &raw)
        return tidy(raw)
    }

    public static func plain(html: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return html }
        return plain(doc)
    }

    private static func render(node: Node, into out: inout String) {
        if let text = node as? TextNode {
            out += text.getWholeText()
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()

        if tag == "br" {
            out += "\n"
            return
        }
        if tag == "img" || tag == "script" || tag == "style" {
            return
        }
        // 链接：只留文字，但外部链接补上地址，否则读者看不到去哪
        if tag == "a" {
            let text = (try? element.text()) ?? ""
            let href = (try? element.attr("href")) ?? ""
            let external = element.hasClass("external") || href.contains("/externalurl/")
            if external, let real = Self.realExternalURL(href) {
                if text.isEmpty || real.absoluteString != text {
                    out += text.isEmpty ? real.absoluteString : "\(text) (\(real.absoluteString))"
                    return
                }
            }
            out += text
            return
        }

        let isBlock = blockTags.contains(tag)
        if isBlock && !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }

        for child in element.getChildNodes() {
            render(node: child, into: &out)
        }

        if isBlock {
            // 块边界只贡献一个换行；空行只来自内容里显式的 <br><br>
            if !out.hasSuffix("\n") { out += "\n" }
        }
    }

    /// FA 把站外链接包成 `/externalurl/?q=<encoded>`
    private static func realExternalURL(_ href: String) -> URL? {
        guard href.contains("/externalurl/"),
              let comps = URLComponents(string: href.hasPrefix("http") ? href : "https://www.furaffinity.net\(href)"),
              let q = comps.queryItems?.first(where: { $0.name == "q" })?.value,
              let url = URL(string: q) else { return nil }
        return url
    }

    /// 收尾：去掉行尾空白、把 3 个以上连续空行压成 1 个、首尾去空
    private static func tidy(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            result.append(line)
        }
        // 去掉末尾空行
        while result.last?.isEmpty == true { result.removeLast() }
        while result.first?.isEmpty == true { result.removeFirst() }
        return result.joined(separator: "\n")
    }
}
