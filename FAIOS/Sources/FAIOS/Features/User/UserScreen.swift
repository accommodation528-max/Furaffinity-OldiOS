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

    func load(slug: String) async {
        guard loadedSlug != slug, !isLoading else { return }
        loadedSlug = slug
        isLoading = true
        defer { isLoading = false }

        do {
            let html = try await FAFetch.html(FAURLs.user(slug))
            let parsed = try FAUserProfile.parse(html, from: FAURLs.user(slug))
            profile = parsed
            await fetchGallery(parsed.galleryURL)
        } catch {
            errorText = FAErrorMessage.describe(error)
            loadedSlug = nil
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
            submissions.append(contentsOf: page.submissions.filter { !existing.contains($0.id) })
            nextPageURL = page.nextPageURL
            galleryLoaded = true
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
        pendingPageURL = nil
    }
}
