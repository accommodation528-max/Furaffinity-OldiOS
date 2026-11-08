import SwiftUI
import FAPages

/// 关注名单：`/watchlist/by/{me}/`（我关注的）与 `/watchlist/to/{me}/`（关注我的）。
///
/// 网页版把这个藏在 controls 里，且只有表格式名单；这里做成可点进艺术家页的列表，
/// 并加一个搜索框——关注几百人时找一个人比翻页快得多。
struct WatchlistScreen: View {

    enum Tab: String, CaseIterable, Identifiable {
        case watching, watchers

        var id: String { rawValue }
        var title: String {
            switch self {
            case .watching: return "我关注的"
            case .watchers: return "关注我的"
            }
        }
    }

    @StateObject private var model = WatchlistViewModel()
    @State private var tab: Tab = .watching
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            searchField

            List {
                ForEach(model.filtered(query)) { entry in
                    NavigationLink(destination: UserScreen(slug: entry.slug)) {
                        HStack(spacing: 10) {
                            Color.clear
                                .frame(width: 30, height: 30)
                                .overlay(RemoteImage(url: FAURLs.avatar(entry.slug),
                                                     contentMode: .fill,
                                                     maxPixelSize: FAImageSize.avatar))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName).font(.subheadline)
                                if entry.displayName.lowercased() != entry.slug {
                                    Text("~\(entry.slug)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }

                if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                }
                if let error = model.errorText {
                    Text(error).font(.caption).foregroundColor(.secondary)
                }
                if !model.isLoading, model.entries.isEmpty, model.errorText == nil {
                    Text(tab == .watching ? "还没关注任何人。" : "还没有人关注你。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .listStyle(.plain)
            .refreshable { await model.load(tab: tab, force: true) }
        }
        .navigationTitle(model.title.isEmpty ? "关注名单" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(tab: tab) }
        .onChange(of: tab) { newValue in
            Task { await model.load(tab: newValue, force: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("在这个名单里搜", text: $query)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(9)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published private(set) var entries: [FAWatchEntry] = []
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private var loadedTab: WatchlistScreen.Tab?

    func load(tab: WatchlistScreen.Tab, force: Bool = false) async {
        if !force, loadedTab == tab, !entries.isEmpty { return }
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        // 关注名单要用自己的用户名拼地址；刚装完/刚登录时还没取到，先抓一次
        if FAAccountStore.shared.slug == nil {
            await FAAccountStore.shared.refreshIfNeeded(force: true)
        }
        guard let slug = FAAccountStore.shared.slug else {
            errorText = "还没取到你的用户名（登录后会自动获取；也可以在「我的」里重新登录）"
            entries = []
            return
        }

        let url = tab == .watching ? FAURLs.watching(slug) : FAURLs.watchers(slug)
        do {
            let html = try await FAFetch.html(url)
            let page = try FAWatchlist.parse(html, from: url)
            entries = page.entries
            title = page.title
            loadedTab = tab
            FADebugLog.log("watchlist \(tab.rawValue) count=\(entries.count)")
        } catch {
            errorText = FAErrorMessage.describe(error)
            entries = []
        }
    }

    /// 本地过滤：名单通常几十到几百人，不值得再发请求
    func filtered(_ query: String) -> [FAWatchEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.slug.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }
}
