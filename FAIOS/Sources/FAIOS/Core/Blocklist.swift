import Foundation
import FAPages

/// 屏蔽词：标题、标签、作者名里命中任意一条，就把这条投稿在列表里藏起来。
///
/// 为什么是「客户端过滤」而不是服务端参数：FA 没有屏蔽接口，而且用户想屏蔽的东西很杂
/// （某个物种、某个 CP、某个画师的某个主题）。所以维护一张词表，在**解析结果**上过滤 ——
/// 好处是无论列表从哪来（首页/浏览/搜索/标签/画廊/关注流）都同一套规则生效。
///
/// 匹配是「包含且不分大小写」：`dog` 会命中 `doggo`、`Dog`、`hotdog`。这是刻意的 ——
/// 用户写 `scat` 时并不想再去穷举 `scat_play`、`scatplay` 这些变体。
/// 需要精确词时把词写长一点即可（`scat_play` 只命中带下划线的）。
@MainActor
final class Blocklist: ObservableObject {

    static let shared = Blocklist()

    private static let key = "fa.blocklist"

    /// 已归一化（小写、去首尾空白）的词表，写入顺序即展示顺序
    @Published private(set) var words: [String] = []

    var isActive: Bool { !words.isEmpty }

    private init() {
        let stored = FAStore.string(Self.key) ?? ""
        words = stored
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// 添加一条，返回 false 表示已经有了 / 空串
    @discardableResult
    func add(_ raw: String) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !words.contains(word) else { return false }
        words.append(word)
        persist()
        return true
    }

    func remove(_ word: String) {
        words.removeAll { $0 == word }
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where words.indices.contains(index) {
            words.remove(at: index)
        }
        persist()
    }

    /// 命中返回命中的那个词（用于告诉用户「被什么挡住的」），没命中返回 nil
    func match(in text: String) -> String? {
        guard isActive, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        // 用 range(of:) 而不是 contains(_:)：String 上的 contains 会跟 Character 版本打架
        return words.first { lower.range(of: $0) != nil }
    }

    /// 列表条目：标题 + 标签 + 作者名一起看
    func match(_ submission: FASubmission) -> String? {
        guard isActive else { return nil }
        if let hit = match(in: submission.title) { return hit }
        if let hit = match(in: submission.authorName) { return hit }
        for tag in Self.tags(from: submission.rawTags) {
            if let hit = match(in: tag) { return hit }
        }
        return nil
    }

    /// `data-tags` 是一整串：`u_spyro1mario c_all t_all s_eastern_dragon male sunbrun`
    ///
    /// 前缀是 FA 自己的分类标记（u_=作者、c_=类别、t_=主题、s_=物种、a_=分级）。
    /// 用户想屏蔽的是「dragon」而不是「s_dragon」，所以每个 token 都要**同时**提供
    /// 原样和去掉前缀的两种形式 —— 只提供一种都会漏。
    static func tags(from rawTags: String) -> [String] {
        var result: [String] = []
        for token in rawTags.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let text = String(token)
            guard !text.isEmpty else { continue }
            result.append(text)
            for prefix in ["u_", "c_", "t_", "s_", "a_"] where text.hasPrefix(prefix) {
                let stripped = String(text.dropFirst(prefix.count))
                if !stripped.isEmpty { result.append(stripped) }
            }
        }
        return result
    }

    /// 详情页：标题 + 全部标签 + 作者名（详情页的标签比列表页全得多）
    func match(detail: FASubmissionDetail) -> String? {
        guard isActive else { return nil }
        if let hit = match(in: detail.title) { return hit }
        if let hit = match(in: detail.authorName) { return hit }
        for tag in detail.tags {
            if let hit = match(in: tag) { return hit }
        }
        return nil
    }

    private func persist() {
        FAStore.set(words.joined(separator: "\n"), for: Self.key)
        NotificationCenter.default.post(name: .faiosBlocklistDidChange, object: nil)
    }
}

extension Notification.Name {
    /// 屏蔽词变化：所有列表据此重拉（可见集合变了，旧数据不能留）
    static let faiosBlocklistDidChange = Notification.Name("faios.blocklist.didChange")
}
