import SwiftUI
import FAPages

/// 站内消息中心（`/msg/others/`）——「谁回复了你、谁发了新投稿、谁关注了你」。
///
/// 页面上是若干**非空才渲染**的分组，所以这里按 `sectionTitle` 分组显示，
/// 而不是硬编码几个固定区块。
struct NotificationsScreen: View {

    @StateObject private var model = NotificationsViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.groups.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
            } else if let error = model.errorText, model.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 32)).foregroundColor(.secondary)
                    Text(error)
                        .font(.footnote).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重试") { Task { await model.reload() } }
                        .font(.footnote)
                }
                .padding(.top, 60)
            } else {
                List {
                    ForEach(model.groups, id: \.title) { group in
                        Section(header: Text(group.title).textCase(nil)) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                row(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await model.reload() }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func row(_ item: FANotification) -> some View {
        // 只有投稿能点进详情页；日志与喊话的页面 M4 再做，先老实显示不可点
        if let url = item.url, let sid = Self.submissionID(from: url) {
            NavigationLink(destination: SubmissionScreen(id: sid, known: nil)) {
                content(item)
            }
        } else {
            content(item)
        }
    }

    private func content(_ item: FANotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(item.kind))
                .font(.footnote)
                .foregroundColor(.orange)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    if let name = item.authorName, !name.isEmpty {
                        Text(name).font(.caption2).foregroundColor(.secondary)
                    }
                    if let posted = item.postedAt {
                        Text("· " + FAFormat.relative(posted))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    if let rating = item.rating, rating != .general {
                        Text(rating == .adult ? "18+" : "M")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(rating == .adult ? Color.red : Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// `/view/66962944/` → 66962944
    static func submissionID(from url: URL) -> Int? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "view" else { return nil }
        return Int(parts[1])
    }

    static func symbol(_ kind: FANotification.Kind) -> String {
        switch kind {
        case .journal: return "book"
        case .submission: return "photo"
        case .comment: return "bubble.left"
        case .shout: return "quote.bubble"
        case .watch: return "person.badge.plus"
        case .favorite: return "heart"
        case .other: return "bell"
        }
    }
}

@MainActor
final class NotificationsViewModel: ObservableObject {

    struct Group {
        let title: String
        let items: [FANotification]
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private var loaded = false

    func load() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let url = FAURLs.msgNotifications
            let html = try await FAFetch.html(url)
            let items = try FANotifications.parse(html, from: url)
            // 保持页面上的分组顺序，同组内按页面顺序
            var order: [String] = []
            var bucket: [String: [FANotification]] = [:]
            for item in items where ContentFilter.shared.allows(item.rating ?? .general) {
                if bucket[item.sectionTitle] == nil {
                    order.append(item.sectionTitle)
                    bucket[item.sectionTitle] = []
                }
                bucket[item.sectionTitle]?.append(item)
            }
            groups = order.map { Group(title: $0, items: bucket[$0] ?? []) }
            loaded = true
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}
