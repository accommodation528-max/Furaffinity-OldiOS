import Foundation

/// 分级。来自 `<figure class="r-general ...">`
public enum FASubmissionRating: String, CaseIterable, Sendable {
    case general = "r-general"
    case mature  = "r-mature"
    case adult   = "r-adult"

    /// 无法识别时的兜底：按最严格处理，避免漏放
    public static let fallback: FASubmissionRating = .adult

    static func from(className: String) -> FASubmissionRating {
        for token in className.split(separator: " ") {
            if let r = FASubmissionRating(rawValue: String(token)) { return r }
        }
        return .fallback
    }

    /// 详情页的分级是 `<img class="c-contentRating--general">`，不是 `r-general`
    static func fromDetailClass(_ className: String) -> FASubmissionRating {
        if className.contains("c-contentRating--general") { return .general }
        if className.contains("c-contentRating--mature") { return .mature }
        if className.contains("c-contentRating--adult") { return .adult }
        return from(className: className)
    }
}

/// 投稿类型。来自 `<figure class="t-image ...">`
public enum FASubmissionKind: String, CaseIterable, Sendable {
    case image = "t-image"   // 图片
    case text  = "t-text"    // 小说 / 文章
    case audio = "t-audio"   // 音乐
    case unknown = ""

    static func from(className: String) -> FASubmissionKind {
        for token in className.split(separator: " ") {
            let s = String(token)
            if s.hasPrefix("t-"), let k = FASubmissionKind(rawValue: s) { return k }
        }
        return fromDetailClass(className)
    }

    /// 详情页换成另一套写法：`submission-image` / `submission-writing` / `submission-music`
    static func fromDetailClass(_ className: String) -> FASubmissionKind {
        if className.contains("submission-writing") { return .text }
        if className.contains("submission-music") { return .audio }
        if className.contains("submission-image") { return .image }
        return .unknown
    }
}

/// 列表页里的一条投稿（`<figure>`）。
/// 注意：只有缩略图信息，没有原图、没有简介——那些要进详情页才有。
public struct FASubmission: Hashable, Sendable, Identifiable {

    public let id: Int
    /// /view/66962680/
    public let url: URL
    public let title: String
    public let authorName: String
    /// /user/spyro1mario/
    public let authorURL: URL
    /// https://t.furaffinity.net/66962680@200-1794055731.jpg
    public let thumbnailURL: URL
    /// 缩略图在页面上的显示尺寸（data-width / data-height），瀑布流布局用
    public let thumbnailWidth: Double
    public let thumbnailHeight: Double
    public let rating: FASubmissionRating
    public let kind: FASubmissionKind
    /// `data-tags` 原始串，形如 "u_xxx c_all t_all s_eastern_dragon male ..."
    public let rawTags: String

    public init(
        id: Int,
        url: URL,
        title: String,
        authorName: String,
        authorURL: URL,
        thumbnailURL: URL,
        thumbnailWidth: Double,
        thumbnailHeight: Double,
        rating: FASubmissionRating,
        kind: FASubmissionKind,
        rawTags: String
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.authorName = authorName
        self.authorURL = authorURL
        self.thumbnailURL = thumbnailURL
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.rating = rating
        self.kind = kind
        self.rawTags = rawTags
    }

    /// 宽高比，0 表示未知（调用方应回退到方形占位）
    public var aspectRatio: Double {
        guard thumbnailHeight > 0 else { return 0 }
        return thumbnailWidth / thumbnailHeight
    }
}
