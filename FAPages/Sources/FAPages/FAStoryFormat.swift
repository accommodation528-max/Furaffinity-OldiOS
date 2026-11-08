import Foundation

/// 文本投稿的文件格式。
///
/// FA 上「故事」类投稿不再内联渲染正文，页面上只有一张封面图 + 一个 `Download` 链接，
/// 点下去拿到的是 docx / pdf / txt / md / rtf —— 所以阅读器的第一件事是**判断格式**。
public enum FAStoryFormat: Equatable, Sendable {

    case plainText      // .txt
    case markdown       // .md / .markdown
    case pdf            // .pdf
    case docx           // .docx / .doc
    case rtf            // .rtf
    case other(String)  // 其余（.odt、.epub……）

    public static func from(_ url: URL) -> FAStoryFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "text": return .plainText
        case "md", "markdown": return .markdown
        case "pdf": return .pdf
        case "docx", "doc": return .docx
        case "rtf": return .rtf
        default: return .other(ext)
        }
    }

    /// 能不能在 App 内直接读
    public var isNativelyReadable: Bool {
        switch self {
        case .plainText, .markdown: return true
        default: return false
        }
    }

    /// 界面上给人看的名字
    public var displayName: String {
        switch self {
        case .plainText: return "纯文本"
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        case .docx: return "Word 文档"
        case .rtf: return "RTF"
        case .other(let ext): return ext.isEmpty ? "未知格式" : ext.uppercased()
        }
    }
}

extension FASubmissionDetail {

    /// 文本投稿的下载地址（`Download` 按钮的 `href`）
    public var storyFormat: FAStoryFormat? {
        guard let downloadURL else { return nil }
        return FAStoryFormat.from(downloadURL)
    }
}
