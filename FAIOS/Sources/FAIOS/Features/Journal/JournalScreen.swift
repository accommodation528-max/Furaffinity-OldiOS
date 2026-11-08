import SwiftUI
import FAPages

/// Journal（日记 / 接稿公告）阅读页。
///
/// 与投稿详情页的区别：这里的主体是一段**长文本**，不是图。
/// 所以排版重点是行距与留白，而不是 hero 图。
struct JournalScreen: View {

    let id: Int

    @StateObject private var model = JournalViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let journal = model.journal {
                    content(journal)
                } else if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
                } else if let error = model.errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 30)).foregroundColor(.secondary)
                        Text(error)
                            .font(.footnote).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await model.reload() } }.font(.footnote)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("日记")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(id: id) }
    }

    @ViewBuilder
    private func content(_ journal: FAJournal) -> some View {
        Text(journal.title)
            .font(.title3).bold()
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            if !journal.authorSlug.isEmpty {
                NavigationLink(destination: UserScreen(slug: journal.authorSlug)) {
                    HStack(spacing: 7) {
                        Color.clear
                            .frame(width: 26, height: 26)
                            .clipShape(Circle())
                            .overlay(RemoteImage(url: journal.authorAvatarURL, contentMode: .fill,
                                                 maxPixelSize: FAImageSize.avatar))
                            .overlay(Circle().stroke(Color.primary.opacity(0.1)))
                        Text(journal.authorName).font(.subheadline)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(journal.authorName).font(.subheadline)
            }

            Spacer()

            if let posted = journal.postedAt {
                Text(FAFormat.dateTime(posted))
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        if journal.rating != .general {
            Text(journal.rating == .adult ? "18+ 成人内容" : "Mature")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(journal.rating == .adult ? Color.red : Color.orange)
                .foregroundColor(.white)
                .cornerRadius(4)
        }

        Divider()

        Text(journal.bodyText)
            .font(.callout)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

        if !journal.comments.isEmpty || journal.commentsDisabled {
            Divider().padding(.top, 6)
            Text(journal.commentsDisabled ? "评论已关闭" : "评论 · \(journal.comments.count)")
                .font(.subheadline).bold()
            ForEach(journal.comments) { comment in
                CommentRow(comment: comment)
                Divider()
            }
        }
    }
}

@MainActor
final class JournalViewModel: ObservableObject {

    @Published private(set) var journal: FAJournal?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private var loadedID: Int?

    func load(id: Int) async {
        guard loadedID != id else { return }
        loadedID = id
        await reload(id: id)
    }

    func reload() async {
        guard let id = loadedID else { return }
        await reload(id: id)
    }

    private func reload(id: Int) async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let url = FAURLs.journal(id)
            let html = try await FAFetch.html(url)
            journal = try FAJournals.parse(html, from: url)
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}
