import SwiftUI
import FAPages

/// 投稿详情页（M1 的主角）。
struct SubmissionScreen: View {

    let id: Int
    /// 从列表页带过来的已知信息 —— 详情没加载完时先用它画占位，避免白屏
    var known: FASubmission?

    @StateObject private var model = SubmissionViewModel()
    @State private var imageRatio: CGFloat?
    @State private var showViewer = false
    /// 被分级过滤挡下时，用户可以选择「这次就看」
    @State private var revealed = false

    private var ratio: CGFloat {
        if let detailRatio = model.detail?.imageURL == nil ? nil : imageRatio { return detailRatio }
        if let known, known.aspectRatio > 0 { return CGFloat(known.aspectRatio) }
        return 4.0 / 3.0
    }

    /// 当前分级设置是否允许看这条投稿（列表层已经过滤过，这里兜住深链进来的情况）
    private var blockedRating: FASubmissionRating? {
        guard let rating = model.detail?.rating ?? known?.rating else { return nil }
        return ContentFilter.shared.allows(rating) ? nil : rating
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .contentShape(Rectangle())
                    .onTapGesture { if model.detail?.imageURL != nil { showViewer = true } }

                VStack(alignment: .leading, spacing: 16) {
                    header
                    tagRow
                    description
                    stats
                    commentsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .overlay {
                if let rating = blockedRating, !revealed {
                    ratingCover(rating)
                }
            }
        }
        .navigationTitle(model.detail?.title ?? known?.title ?? "投稿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.detail?.favoriteURL != nil {
                    Button {
                        Task { await model.toggleFavorite() }
                    } label: {
                        Image(systemName: model.favorited ? "heart.fill" : "heart")
                            .foregroundColor(model.favorited ? .pink : .accentColor)
                    }
                    .disabled(model.favoriteBusy)
                }
            }
        }
        .task(id: id) { await model.load(id: id) }
        .fullScreenCover(isPresented: $showViewer) {
            if let url = model.detail?.imageURL {
                ImageViewerScreen(url: url, title: model.detail?.title ?? "")
            }
        }
    }

    /// 分级遮罩：默认盖住内容，明确告诉用户「为什么看不到」，并留一个自主放行的口子
    private func ratingCover(_ rating: FASubmissionRating) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: rating == .adult ? "exclamationmark.triangle.fill" : "eye.slash.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.orange)
                Text("已按内容分级隐藏")
                    .font(.headline)
                Text("这条投稿的分级是 \(rating == .adult ? "Adult（露骨）" : "Mature（成人向）")，当前设置为「\(ContentFilter.shared.mode.title)」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                Button {
                    revealed = true
                } label: {
                    Text("这次显示").font(.subheadline).bold()
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.16))
                        .cornerRadius(9)
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
    }

    // MARK: - 大图

    private var hero: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(
                RemoteImage(
                    url: model.detail?.previewURL ?? model.detail?.imageURL ?? known?.thumbnailURL,
                    contentMode: .fit,
                    maxPixelSize: FAImageSize.hero,
                    onLoad: { size in
                        guard size.height > 0 else { return }
                        let newRatio = size.width / size.height
                        if abs(newRatio - (imageRatio ?? 0)) > 0.01 { imageRatio = newRatio }
                    }
                )
            )
            .background(Color.secondary.opacity(0.06))
    }

    // MARK: - 标题 / 作者

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detail = model.detail {
                Text(detail.title)
                    .font(.title3).bold()
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink(destination: UserScreen(slug: detail.authorSlug)) {
                    HStack(spacing: 8) {
                        Color.clear
                            .frame(width: 30, height: 30)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(RemoteImage(url: detail.authorAvatarURL, contentMode: .fill,
                                                 maxPixelSize: FAImageSize.avatar))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(detail.authorName)
                                .font(.subheadline).bold()
                                .foregroundColor(.primary)
                            if let posted = detail.postedAt {
                                Text(Self.dateFormatter.string(from: posted))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if let known {
                Text(known.title).font(.title3).bold()
                Text("by \(known.authorName)").font(.subheadline).foregroundColor(.secondary)
                if model.isLoading { ProgressView().scaleEffect(0.8) }
            }

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 标签

    private var tagRow: some View {
        Group {
            if let tags = model.detail?.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.14))
                                .cornerRadius(9)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
            }
        }
    }

    // MARK: - 描述

    private var description: some View {
        Group {
            if let text = model.detail?.descriptionText, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 统计

    private var stats: some View {
        Group {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        statItem("eye", detail.views)
                        statItem("bubble.left", detail.commentCount)
                        statItem("heart", detail.favoriteCount)
                        Spacer()
                    }
                    if !detail.attributes.isEmpty {
                        ForEach(detail.attributes.indices, id: \.self) { index in
                            let pair = detail.attributes[index]
                            HStack(alignment: .top, spacing: 8) {
                                Text(pair.0)
                                    .font(.caption).foregroundColor(.secondary)
                                    .frame(width: 84, alignment: .leading)
                                Text(pair.1)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statItem(_ symbol: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption)
            Text(value.map(String.init) ?? "–").font(.caption)
        }
        .foregroundColor(.secondary)
    }

    // MARK: - 评论

    private var commentsSection: some View {
        Group {
            if !model.comments.isEmpty || model.commentsDisabled {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().padding(.vertical, 2)

                    Text(model.commentsDisabled ? "评论已关闭" : "评论 · \(model.comments.count)")
                        .font(.subheadline).bold()

                    ForEach(model.comments) { comment in
                        CommentRow(comment: comment)
                    }
                }
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

@MainActor
final class SubmissionViewModel: ObservableObject {
    @Published private(set) var detail: FASubmissionDetail?
    @Published private(set) var comments: [FAComment] = []
    @Published private(set) var commentsDisabled = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    /// 收藏状态单独存一份：详情对象是值类型，重载一次才刷新，
    /// 而按钮需要在点下去之后立刻变。
    @Published private(set) var favorited = false
    @Published private(set) var favoriteBusy = false

    private var loadedID: Int?

    func load(id: Int) async {
        guard loadedID != id else { return }
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let url = FAURLs.submission(id)
        do {
            let html = try await FAFetch.html(url)
            let parsed = try FASubmissionDetail.parse(html, from: url)
            detail = parsed
            favorited = parsed.isFavorited
            // 评论和详情同页，一次请求全解析出来，避免多一次往返（FA 限速是真的）
            comments = (try? FAComments.parse(html, from: url)) ?? []
            commentsDisabled = FAComments.areCommentsDisabled(in: html)
            loadedID = id
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }

    /// 收藏 / 取消收藏。
    ///
    /// 收藏地址（带 token）就在详情页的按钮 href 上，GET 一下就切换。
    /// 但**不能拿这个响应当结果**：FA 的 302 目标并不总是详情页（实测关注动作会跳到
    /// 一个结构不同的页面，解析出来的作者名都是错的）。所以：先乐观地把界面翻过去，
    /// 再老实重取一次详情页确认，不一致就翻回来并提示。
    func toggleFavorite() async {
        guard let detail, let actionURL = detail.favoriteURL, !favoriteBusy else { return }
        favoriteBusy = true
        defer { favoriteBusy = false }

        let wanted = !favorited
        let previous = favorited
        favorited = wanted

        do {
            _ = try await FAFetch.perform(actionURL)
            let url = FAURLs.submission(detail.id)
            let page = try await FAFetch.html(url)
            let fresh = try FASubmissionDetail.parse(page, from: url)
            self.detail = fresh
            favorited = fresh.isFavorited
            if fresh.isFavorited != wanted {
                favorited = previous
                errorText = "收藏没生效（服务器可能限速了，稍后再试）"
            } else {
                errorText = nil
            }
        } catch {
            favorited = previous
            errorText = FAErrorMessage.describe(error)
        }
    }
}

/// 一条评论：头像 + 名字 + 时间 + 正文；回复按层级缩进。
struct CommentRow: View {
    let comment: FAComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear
                .frame(width: 26, height: 26)
                .overlay(RemoteImage(url: comment.avatarURL, contentMode: .fill,
                                     maxPixelSize: FAImageSize.avatar))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.caption).bold()
                        .lineLimit(1)
                    if let title = comment.title {
                        Text(title)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let posted = comment.postedAt {
                        Text(FAFormat.relative(posted))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Text(comment.body)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, CGFloat(min(comment.depth, 4)) * 18)
    }
}
