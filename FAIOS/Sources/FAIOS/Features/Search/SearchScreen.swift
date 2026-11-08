import SwiftUI
import FAPages

/// 搜索屏：顶部搜索框 + 结果网格（结果复用 `BrowseScreen`，它认 `search()` 页的分页表单）。
///
/// iOS 15 上 `.searchable` 在 `NavigationView` 里表现不稳定（键盘收起时经常丢焦点），
/// 这里自绘搜索框：一个 HStack + TextField，配 `@FocusState` 收键盘。
struct SearchScreen: View {

    @State private var query: String = ""
    /// 只有按了回车才会变；它是「已提交的关键词」，同时用来当 BrowseScreen 的 .id
    @State private var submitted: String?
    @State private var recent: [String] = SearchHistory.load()
    @FocusState private var isFocused: Bool

    private let suggestions = ["dragon", "wolf", "pokemon", "commission", "sergal", "anthro"]

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if let submitted {
                BrowseScreen(startURL: FAURLs.search(submitted), title: submitted)
                    .id(submitted)          // 换词就整屏重建，别让旧结果残留
            } else {
                idleContent
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            TextField("标签、作者、关键词", text: $query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit { submit(query) }

            if !query.isEmpty {
                Button {
                    query = ""
                    submitted = nil
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 未搜索时

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !recent.isEmpty {
                    section("最近搜索", terms: recent, symbol: "clock.arrow.circlepath") { term in
                        query = term
                        submit(term)
                    }
                }
                section("试试这些", terms: suggestions, symbol: "tag") { term in
                    query = term
                    submit(term)
                }

                Text("搜索走 `/search/?q=`，结果页与首页同一套 `<figure>` 结构，所以分页、去重、进详情都是同一份代码。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
        }
    }

    private func section(_ title: String,
                         terms: [String],
                         symbol: String,
                         tap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
            FlowChips(terms: terms, tap: tap)
        }
    }

    private func submit(_ raw: String) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isFocused = false
        submitted = term
        recent = SearchHistory.push(term)
    }
}

/// 简易标签流：每行最多 3 个，iOS 15 没有 `Layout` 协议，这样排最省心也不会被裁
struct FlowChips: View {
    let terms: [String]
    let tap: (String) -> Void

    private var rows: [[String]] {
        stride(from: 0, to: terms.count, by: 3).map {
            Array(terms[$0 ..< min($0 + 3, terms.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { term in
                        Button {
                            tap(term)
                        } label: {
                            Text(term)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(13)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// 搜索历史：存一个数组，去重、最新的在前、上限 12 条。
/// 走 `FAStore` 而不是 UserDefaults —— 这台机器上 UserDefaults 写不进磁盘。
@MainActor
enum SearchHistory {
    private static let key = "fa.searchHistory"

    static func load() -> [String] {
        guard let raw = FAStore.string(key), let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    static func push(_ term: String) -> [String] {
        var list = load().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        if let data = try? JSONEncoder().encode(list), let raw = String(data: data, encoding: .utf8) {
            FAStore.set(raw, for: key)
        }
        return list
    }
}
