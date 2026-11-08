import Foundation
import FAPages

/// 内容分级过滤（SFW / NSFW 开关）。
///
/// FA 给每个投稿标了三级：`general`（全年龄）、`mature`（成人向但不算露骨）、`adult`（露骨）。
/// 未登录时服务端只给 general；登录后才会把另外两级下发，所以「看不看得到」最终由
/// **服务端**决定，我们这里做的是**在已下发的范围里再收窄**：
///
/// - 过滤在**列表层**做（首页 / 浏览 / 搜索 / 艺术家画廊），拿的是解析出来的 `rating`，
///   不依赖任何服务端参数 —— 换页面、换接口都不会失效。
/// - 浏览页额外把分级参数拼进 URL，让服务端少返回我们不要的东西；
///   但这只是优化，不是正确性来源。
///
/// 分级是**累积**的：`adult` 比 `mature` 更重，所以「允许 mature」必然「允许 general」。
@MainActor
final class ContentFilter: ObservableObject {

    static let shared = ContentFilter()

    enum Mode: String, CaseIterable, Identifiable {
        case all
        case noAdult
        case sfw

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .noAdult: return "隐藏 Adult"
            case .sfw: return "只看 General"
            }
        }

        /// 设置页里的一句话说明
        var detail: String {
            switch self {
            case .all: return "General + Mature + Adult"
            case .noAdult: return "隐藏露骨内容，保留 Mature"
            case .sfw: return "全年龄，最保守"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "eye"
            case .noAdult: return "eye.slash"
            case .sfw: return "checkmark.shield"
            }
        }

        func allows(_ rating: FASubmissionRating) -> Bool {
            switch self {
            case .all: return true
            case .noAdult: return rating != .adult
            case .sfw: return rating == .general
            }
        }

        /// 浏览/搜索页的查询参数（1 = 要，0 = 不要）。名字来自页面里那组 hidden input。
        var queryItems: [URLQueryItem] {
            [
                URLQueryItem(name: "rating_general", value: "1"),
                URLQueryItem(name: "rating_mature", value: self == .sfw ? "0" : "1"),
                URLQueryItem(name: "rating_adult", value: self == .all ? "1" : "0")
            ]
        }
    }

    private static let storageKey = "fa.contentMode"

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            FAStore.set(mode.rawValue, for: Self.storageKey)
            NotificationCenter.default.post(name: .faiosContentModeDidChange, object: nil)
        }
    }

    private init() {
        let saved = FAStore.string(Self.storageKey)
        mode = saved.flatMap(Mode.init(rawValue:)) ?? .all
    }

    func allows(_ rating: FASubmissionRating) -> Bool {
        mode.allows(rating)
    }
}

extension Notification.Name {
    /// 分级设置变了 —— 所有已经拉过数据的列表都要重拉（它们的可见集合变了）
    static let faiosContentModeDidChange = Notification.Name("faiosContentModeDidChange")
}

extension URL {
    /// 把分级参数并进列表页 URL（只在浏览/搜索这种「服务端认参数」的页面上用）。
    /// 已有同名参数会被覆盖，避免出现 `page=2` 这种带着旧分级翻页的情况。
    func applyingRatingFilter(_ mode: ContentFilter.Mode) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = components.queryItems ?? []
        for newItem in mode.queryItems {
            items.removeAll { $0.name == newItem.name }
            items.append(newItem)
        }
        components.queryItems = items
        return components.url ?? self
    }
}
