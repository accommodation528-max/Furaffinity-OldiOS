import SwiftUI
import FAPages

/// 艺术家主页：资料头 + 画廊网格。
struct UserScreen: View {

    let slug: String

    @StateObject private var model = UserViewModel()

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let profile = model.profile {
                    header(profile)
                } else if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                }

                if let error = model.errorText {
                    Text(error)
                        .font(.caption).foregroundColor(.red)
                        .padding(.horizontal, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.submissions.isEmpty {
                    grid
                } else if model.profile != nil, model.galleryLoaded {
                    Text("画廊是空的")
                        .font(.footnote).foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle(model.profile?.displayName ?? slug)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: slug) { await model.load(slug: slug) }
        .onReceive(NotificationCenter.default.publisher(for: .faiosContentModeDidChange)) { _ in
            Task { await model.reloadGallery() }
        }
    }

    // MARK: - 资料头

    private func header(_ profile: FAUserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Color.clear
                    .frame(width: 64, height: 64)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(RemoteImage(url: profile.avatarURL, contentMode: .fill))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.title3).bold()
                    if let registered = profile.registeredAt {
                        Text("加入于 " + Self.yearFormatter.string(from: registered))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let watchers = profile.watchersCount {
                            Label("\(watchers)", systemImage: "person.2")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Label("\(model.submissions.count)+", systemImage: "photo.on.rectangle")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()

                // 关注按钮只在登录后出现（未登录页没有这个 href）
                if model.watchURL != nil {
                    Button {
                        Task { await model.toggleWatch() }
                    } label: {
                        Text(model.isWatching ? "已关注" : "关注")
                            .font(.caption).bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(model.isWatching ? Color.secondary.opacity(0.16) : Color.orange)
                            .foregroundColor(model.isWatching ? Color.secondary : Color.white)
                            .cornerRadius(8)
                    }
                    .disabled(model.watchBusy)
                }
            }
            .padding(.horizontal, 14)

            // 页面导航：Gallery / Scraps / Favs / Journals（M1 先只显示，切换留给 M2）
            if !profile.navLinks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profile.navLinks.indices, id: \.self) { index in
                            let link = profile.navLinks[index]
                            Text(link.title)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    link.title.lowercased() == "home"
                                        ? Color.orange.opacity(0.2)
                                        : Color.secondary.opacity(0.14)
                                )
                                .cornerRadius(9)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    // MARK: - 网格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(model.submissions) { submission in
                NavigationLink(destination: SubmissionScreen(id: submission.id, known: submission)) {
                    ThumbnailCell(submission: submission)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadMoreIfNeeded(current: submission) }
            }
        }
        .padding(.horizontal, 4)
    }

    static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()
}

@MainActor
final class UserViewModel: ObservableObject {
    @Published private(set) var profile: FAUserProfile?
    @Published private(set) var submissions: [FASubmission] = []
    @Published private(set) var isLoading = false
    @Published private(set) var galleryLoaded = false
    @Published private(set) var errorText: String?

    private var nextPageURL: URL?
    private var pendingPageURL: URL?
    private var loadedSlug: String?

    /// 关注状态：和详情页的收藏一样，点完立刻变，不等整页重拉
    @Published private(set) var isWatching = false
    @Published private(set) var watchURL: URL?
    @Published private(set) var watchBusy = false

    func load(slug: String) async {
        guard loadedSlug != slug, !isLoading else { return }
        loadedSlug = slug
        isLoading = true
        defer { isLoading = false }

        do {
            let html = try await FAFetch.html(FAURLs.user(slug))
            let parsed = try FAUserProfile.parse(html, from: FAURLs.user(slug))
            profile = parsed
            isWatching = parsed.isWatching
            watchURL = parsed.watchURL
            await fetchGallery(parsed.galleryURL)
        } catch {
            errorText = FAErrorMessage.describe(error)
            loadedSlug = nil
        }
    }

    /// 关注 / 取消关注：href 上带 key，GET 即可（和收藏同一套机制）。
    ///
    /// 同样**不能拿动作的响应当结果** —— 实测 `/watch/{user}/?key=` 回来的页面结构
    /// 跟用户页不一样（作者名、头像、统计全对不上）。乐观翻转 + 重取用户页确认。
    func toggleWatch() async {
        guard let url = watchURL, let slug = loadedSlug, !watchBusy else { return }
        watchBusy = true
        defer { watchBusy = false }

        let wanted = !isWatching
        let previous = isWatching
        isWatching = wanted

        do {
            _ = try await FAFetch.perform(url)
            let userURL = FAURLs.user(slug)
            let html = try await FAFetch.html(userURL)
            let fresh = try FAUserProfile.parse(html, from: userURL)
            profile = fresh
            isWatching = fresh.isWatching
            watchURL = fresh.watchURL
            if fresh.isWatching != wanted {
                isWatching = previous
                errorText = "关注没生效（服务器可能限速了，稍后再试）"
            } else {
                errorText = nil
            }
        } catch {
            isWatching = previous
            errorText = FAErrorMessage.describe(error)
        }
    }

    func loadMoreIfNeeded(current: FASubmission) {
        guard current.id == submissions.last?.id, let next = nextPageURL, !isLoading else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            await fetchGallery(next)
        }
    }

    private func fetchGallery(_ url: URL) async {
        guard pendingPageURL != url else { return }
        pendingPageURL = url
        do {
            let html = try await FAFetch.html(url)
            let page = try FASubmissionsPage.parse(html, from: url)
            let existing = Set(submissions.map { $0.id })
            submissions.append(contentsOf: page.submissions.filter {
                !existing.contains($0.id) && ContentFilter.shared.allows($0.rating)
            })
            nextPageURL = page.nextPageURL
            galleryLoaded = true
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
        pendingPageURL = nil
    }

    /// 分级设置变了：从头再拉一次画廊（资料头不用重拉）
    func reloadGallery() async {
        guard let galleryURL = profile?.galleryURL else { return }
        submissions = []
        nextPageURL = nil
        pendingPageURL = nil
        galleryLoaded = false
        await fetchGallery(galleryURL)
    }
}
