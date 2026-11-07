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
    }
}

struct ThumbnailCell: View {
    let submission: FASubmission

    var body: some View {
        Color.clear
            .aspectRatio(submission.aspectRatio > 0 ? submission.aspectRatio : 1, contentMode: .fit)
            .overlay(
                RemoteImage(url: submission.thumbnailURL)
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

        do {
            let url = nextPageURL ?? startURL
            // 防死循环：解析器要是指回同一个 URL，就当到底了
            let previousPageURL = nextPageURL
            let html = try await FAHTTP.shared.fetchHTML(url)
            let page = try FASubmissionsPage.parse(html, from: url)
            let known = Set(submissions.map { $0.id })
            let fresh = page.submissions.filter { !known.contains($0.id) }
            submissions.append(contentsOf: fresh)
            nextPageURL = (page.nextPageURL == url || page.nextPageURL == previousPageURL) ? nil : page.nextPageURL
            FADebugLog.log("browse \(url.lastPathComponent) +\(fresh.count) total=\(submissions.count) next=\(nextPageURL == nil ? "nil" : "yes")")
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }

    /// 滚动到接近底部就预取下一页（LazyVGrid 的 onAppear 只在最后一条触发太晚，网络一慢就卡住）
    func loadMoreIfNeeded(current: FASubmission) {
        guard let index = submissions.lastIndex(where: { $0.id == current.id }) else { return }
        guard index >= submissions.count - 12 else { return }
        guard nextPageURL != nil, !isLoading else { return }
        Task { await load() }
    }
}
