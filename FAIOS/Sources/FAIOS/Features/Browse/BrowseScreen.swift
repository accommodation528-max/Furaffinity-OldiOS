import SwiftUI
import FAPages

/// 列表屏（首页/浏览/搜索/画廊共用一套 `<figure>` 结构）。
/// M0 时它是「端到端证明」屏；M1 加了无限滚动，并接上真正的详情页。
struct BrowseScreen: View {

    /// 列表页地址；首页与浏览页只是这里传的参数不同
    @StateObject private var model: BrowseViewModel
    private let title: String

    private let columns = [
        GridItem(.adaptive(minimum: 108), spacing: 3)
    ]

    init(startURL: URL = FAURLs.browse, title: String = "浏览") {
        _model = StateObject(wrappedValue: BrowseViewModel(startURL: startURL))
        self.title = title
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(model.submissions) { submission in
                    NavigationLink(destination: SubmissionScreen(id: submission.id, known: submission)) {
                        ThumbnailCell(submission: submission)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadMoreIfNeeded(current: submission) }
                }
            }
            .padding(.horizontal, 3)

            if model.isLoading {
                ProgressView().padding()
            }
            if let error = model.errorText {
                VStack(spacing: 6) {
                    Text("加载失败").font(.footnote).bold()
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            if !model.submissions.isEmpty, !model.isLoading {
                // 顺带当调试用：数字会一直涨，说明翻页真的在跑
                Text(model.nextPageURL == nil ? "到底了 · 共 \(model.submissions.count) 张"
                                              : "已加载 \(model.submissions.count) 张")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .navigationTitle(model.submissions.isEmpty ? title : "\(title) · \(model.submissions.count)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task {
            if model.submissions.isEmpty { await model.load() }
        }
        // 登录/退出后列表的可见范围会变（未登录看不到成人内容），必须重拉
        .onReceive(NotificationCenter.default.publisher(for: .faiosLoginDidChange)) { _ in
            Task { await model.reload() }
        }
        // 改了分级过滤同理：可见集合变了，旧数据不能留
        .onReceive(NotificationCenter.default.publisher(for: .faiosContentModeDidChange)) { _ in
            Task { await model.reload() }
        }
    }
}

struct ThumbnailCell: View {
    let submission: FASubmission

    /// 网格里要「大致按真实比例」但必须夹住极端值：
    /// 长条漫画（1:8）或全景（6:1）会让整行变成 1000pt 高，把屏幕撑成一张图 —— 真机上就是这么翻车的
    private var displayRatio: CGFloat {
        let ratio = submission.aspectRatio
        guard ratio > 0 else { return 1 }
        return min(max(ratio, 0.62), 1.7)
    }

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(displayRatio, contentMode: .fit)
            .overlay(
                // 列表页给的是 @200 缩略图，在视网膜屏上偏糊，往上提一档
                RemoteImage(url: FAURLs.thumbnailSized(submission.thumbnailURL))
            )
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if submission.kind != .image {
                    Image(systemName: submission.kind == .text ? "text.alignleft" : "music.note")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(.ultraThinMaterial)
                        .cornerRadius(3)
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge = Self.ratingBadge(submission.rating) {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(submission.rating == .adult ? Color.red.opacity(0.85) : Color.orange.opacity(0.85))
                        .cornerRadius(3)
                        .padding(3)
                }
            }
    }

    /// 角标只标「需要注意」的：General 不打扰，Mature/Adult 各给一个记号
    static func ratingBadge(_ rating: FASubmissionRating) -> String? {
        switch rating {
        case .general: return nil
        case .mature: return "M"
        case .adult: return "18+"
        }
    }
}

@MainActor
final class BrowseViewModel: ObservableObject {
    @Published private(set) var submissions: [FASubmission] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var nextPageURL: URL?

    private let startURL: URL

    init(startURL: URL = FAURLs.browse) {
        self.startURL = startURL
    }

    func reload() async {
        submissions = []
        nextPageURL = nil
        errorText = nil
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        // 分级过滤后一整页可能全是不要的（比如 SFW 模式下刚好一页都是成人向），
        // 这时要自动续下一页，否则用户只看到一屏空白。上限 4 页，防止在极端过滤条件下无限翻。
        var rounds = 0
        while rounds < 4 {
            rounds += 1
            let url = nextPageURL ?? startURL
            // 防死循环：解析器要是指回同一个 URL，就当到底了
            let previousPageURL = nextPageURL

            do {
                let requestURL = Self.supportsRatingParams(url)
                    ? url.applyingRatingFilter(ContentFilter.shared.mode)
                    : url
                let html = try await FAFetch.html(requestURL)
                let page = try FASubmissionsPage.parse(html, from: requestURL)
                let known = Set(submissions.map { $0.id })
                let fresh = page.submissions.filter {
                    !known.contains($0.id) && ContentFilter.shared.allows($0.rating)
                }
                let before = submissions.count
                submissions.append(contentsOf: fresh)
                nextPageURL = (page.nextPageURL == url || page.nextPageURL == previousPageURL)
                    ? nil
                    : page.nextPageURL
                FADebugLog.log("browse \(url.lastPathComponent) +\(fresh.count)/\(page.submissions.count) total=\(submissions.count)")

                // 这一页确实给了新内容，就交给用户看；空页且还有下一页则继续翻
                if submissions.count > before || nextPageURL == nil { return }
            } catch {
                errorText = FAErrorMessage.describe(error)
                return
            }
        }
    }

    /// 只有服务端认分级参数的页面才拼这些参数（浏览页实测认；首页/艺术家页不认，靠本地过滤）
    private static func supportsRatingParams(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/browse") || path.hasPrefix("/search")
    }

    /// 滚动到接近底部就预取下一页（LazyVGrid 的 onAppear 只在最后一条触发太晚，网络一慢就卡住）
    func loadMoreIfNeeded(current: FASubmission) {
        guard let index = submissions.lastIndex(where: { $0.id == current.id }) else { return }
        guard index >= submissions.count - 12 else { return }
        guard nextPageURL != nil, !isLoading else { return }
        Task { await load() }
    }
}
