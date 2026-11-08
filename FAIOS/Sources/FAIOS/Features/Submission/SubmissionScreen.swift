import SwiftUI
import FAPages

/// 投稿详情页（M1 的主角）。
struct SubmissionScreen: View {

    let id: Int
    /// 从列表页带过来的已知信息 —— 详情没加载完时先用它画占位，避免白屏
    var known: FASubmission?
    /// 列表上下文：有它就能左右翻作品、整页跳（网页版最缺的东西）
    var feed: BrowseViewModel?

    @StateObject private var model = SubmissionViewModel()
    @State private var imageRatio: CGFloat?
    @State private var showViewer = false
    /// 被分级过滤挡下时，用户可以选择「这次就看」
    @State private var revealed = false
    /// 翻页后显示的那一条（初始是外部传进来的 id）
    @State private var currentID: Int?
    /// 点了哪个标签（用它驱动隐藏的 NavigationLink，避免横向 ScrollView 吞掉点击）
    @State private var tagToOpen: String?
    /// 原图下载状态：非 nil 时顶部显示一行提示
    @State private var downloadNote: String?
    @State private var downloading = false

    private var activeID: Int { currentID ?? id }

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

    /// 命中了哪个屏蔽词（列表层已经过滤过，这里兜住深链 / 相关链接进来的情况）
    private var blockedWord: String? {
        if let detail = model.detail { return Blocklist.shared.match(detail: detail) }
        if let known { return Blocklist.shared.match(known) }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .contentShape(Rectangle())
                    .onTapGesture { if model.detail?.imageURL != nil { showViewer = true } }

                VStack(alignment: .leading, spacing: 16) {
                    header
                    musicCard
                    tagRow
                    description
                    stats
                    commentsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .overlay {
                if let word = blockedWord, !revealed {
                    blockCover(word)
                } else if let rating = blockedRating, !revealed {
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
                    .accessibilityLabel(model.favorited ? "取消收藏" : "收藏")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        downloadOriginal()
                    } label: {
                        Label("下载原图", systemImage: "arrow.down.to.line")
                    }
                    .disabled(model.detail?.imageURL == nil || downloading)

                    Button {
                        if let url = model.detail?.imageURL {
                            UIPasteboard.general.string = url.absoluteString
                            showNote("原图链接已复制")
                        }
                    } label: {
                        Label("复制原图链接", systemImage: "link")
                    }
                    .disabled(model.detail?.imageURL == nil)

                    Divider()

                    Button {
                        if let name = model.detail?.authorName {
                            Blocklist.shared.add(name)
                            showNote("已屏蔽作者：\(name)")
                        }
                    } label: {
                        Label("屏蔽这位作者", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(model.detail?.authorName == nil)

                    if let tags = model.detail?.tags, !tags.isEmpty {
                        Menu {
                            ForEach(tags, id: \.self) { tag in
                                Button(tag) {
                                    Blocklist.shared.add(tag)
                                    showNote("已屏蔽标签：\(tag)")
                                }
                            }
                        } label: {
                            Label("屏蔽某个标签", systemImage: "tag.fill")
                        }
                    }
                } label: {
                    Image(systemName: downloading ? "arrow.down.circle.fill" : "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .overlay(alignment: .top) {
            if let note = downloadNote {
                Text(note)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .cornerRadius(9)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .task(id: activeID) { await model.load(id: activeID) }
        .safeAreaInset(edge: .bottom) {
            if let feed {
                SubmissionNavBar(feed: feed, id: activeID) { nextID in
                    currentID = nextID
                    revealed = false
                    imageRatio = nil
                    feed.prefetchIfNeeded(around: nextID)
                }
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let url = model.detail?.imageURL {
                ImageViewerScreen(url: url, title: model.detail?.title ?? "")
            }
        }
    }

    // MARK: - 原图下载

    /// 下载原图到「文件」App 可见的目录。
    /// 列表页的 `figure` 里只有 @600 缩略图地址，原图（`data-fullview-src`）只有详情页才拿得到 ——
    /// 所以「单张原图」放在这里，「批量」放在列表页，两者的数据来源本来就不同。
    private func downloadOriginal() {
        guard let url = model.detail?.imageURL else { return }
        downloading = true
        Task {
            do {
                let data = try await FAFetch.data(url)
                guard let folder = BatchDownloader.directory() else {
                    throw FAHTTP.FAHTTPError.http(500)
                }
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                let target = folder.appendingPathComponent("\(activeID).\(ext)")
                try data.write(to: target, options: .atomic)
                downloading = false
                showNote("已保存原图（\(data.count / 1024) KB）到 FAIOS/downloads")
            } catch {
                downloading = false
                showNote(FAErrorMessage.describe(error))
            }
        }
    }

    private func showNote(_ text: String) {
        withAnimation { downloadNote = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { downloadNote = nil }
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

    /// 屏蔽词遮罩：跟分级遮罩一样是「解释 + 一次放行」，只是原因不同。
    /// 单独一套文案是必要的 —— 「被屏蔽词挡住」和「分级不允许」是两件事，
    /// 混在一起用户就分不清是设置问题还是内容问题。
    private func blockCover(_ word: String) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "nosign")
                    .font(.system(size: 34))
                    .foregroundColor(.orange)
                Text("已被屏蔽词隐藏")
                    .font(.headline)
                Text("这条投稿命中了屏蔽词「\(word)」（看标题、作者名或标签）。")
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

                // 故事（.text）正文不在页面里，只有一个下载链接 —— 给条显眼的入口
                if detail.kind == .text {
                    NavigationLink(destination: StoryScreen(detail: detail)) {
                        HStack(spacing: 9) {
                            Image(systemName: detail.storyFormat?.isNativelyReadable == true ? "book" : "arrow.down.doc")
                            Text(detail.storyFormat?.isNativelyReadable == true ? "阅读这篇" : "下载 / 打开")
                                .fontWeight(.semibold)
                            Spacer()
                            if let format = detail.storyFormat {
                                Text(format.displayName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color.orange.opacity(0.14))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
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

    /// 音乐播放卡片（`.audio` 投稿的音频直链在 `detail.musicURL`）
    @ViewBuilder
    private var musicCard: some View {
        if let detail = model.detail, detail.kind == .audio, detail.musicURL != nil {
            MusicCard(detail: detail)
        }
    }

    // MARK: - 标签

    private var tagRow: some View {
        Group {
            if let tags = model.detail?.tags, !tags.isEmpty {
                // 点标签就按这个标签去搜 —— 网页版要手动复制到搜索框，这里一步到位。
                // 注意不能把 chip 放进横向 ScrollView：实测那层滚动手势会把点击吃掉
                // （点上去毫无反应，只有手指真实滑动才生效），所以改成自动换行的流式布局。
                FlowChips(terms: tags, labelFormat: "按标签 %@ 查看列表") { tag in
                    tagToOpen = tag
                }
            }
        }
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { tagToOpen != nil },
                    set: { if !$0 { tagToOpen = nil } }
                ),
                destination: {
                    BrowseScreen(startURL: FAURLs.tag(tagToOpen ?? ""), title: "#\(tagToOpen ?? "")")
                },
                label: { EmptyView() }
            )
            .hidden()
        )
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

/// 详情页底部的翻页条：`«` 上一页、`‹` 上一个作品、`›` 下一个作品、`»` 下一页。
///
/// 网页版最难受的就是这个 —— 看完一张要退回列表再点下一张。这里直接在详情页里翻，
/// 而且知道自己在列表里的位置（`12 / 48`），翻到列表末尾会自动把下一页拉回来。
struct SubmissionNavBar: View {
    @ObservedObject var feed: BrowseViewModel
    let id: Int
    let onSelect: (Int) -> Void

    @State private var busy = false

    private var hasPrevious: Bool { feed.neighbour(of: id, offset: -1) != nil }
    private var hasNext: Bool { feed.neighbour(of: id, offset: 1) != nil || feed.nextPageURL != nil }
    private var hasPreviousPage: Bool { feed.pageStart(before: id) != nil }
    private var hasNextPage: Bool { feed.pageStart(afterLoadedOnly: id) != nil || feed.nextPageURL != nil }
    private var counter: (position: String, detail: String) { feed.pageCounterLabel(of: id) }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                button("backward.end.fill", label: "上一页", enabled: hasPreviousPage) {
                    if let target = feed.pageStart(before: id) { onSelect(target) }
                }
                button("chevron.left", label: "上一个作品", enabled: hasPrevious) {
                    go(offset: -1)
                }

                Spacer(minLength: 0)

                VStack(spacing: 1) {
                    Text(counter.position)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(counter.detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(minWidth: 78)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("本页第 \(counter.position) 张，\(counter.detail)")
                .accessibilityAddTraits(.isStaticText)

                Spacer(minLength: 0)

                button("chevron.right", label: "下一个作品", enabled: hasNext) {
                    go(offset: 1)
                }
                button("forward.end.fill", label: "下一页", enabled: hasNextPage) {
                    goPage()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            .background(.regularMaterial)
        }
    }

    private func button(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.28)
    }

    /// 前后翻作品：撞到已加载列表的边缘就先把下一页拉回来，再走一步
    private func go(offset: Int) {
        if let target = feed.neighbour(of: id, offset: offset) {
            onSelect(target)
            return
        }
        guard offset > 0, feed.nextPageURL != nil, !busy else { return }
        busy = true
        Task {
            await feed.load()
            busy = false
            if let target = feed.neighbour(of: id, offset: offset) { onSelect(target) }
        }
    }

    private func goPage() {
        guard !busy else { return }
        busy = true
        Task {
            if let target = await feed.pageStart(after: id) { onSelect(target) }
            busy = false
        }
    }
}
