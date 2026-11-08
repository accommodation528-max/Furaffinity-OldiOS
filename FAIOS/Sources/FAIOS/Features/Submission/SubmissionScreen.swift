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

    private var ratio: CGFloat {
        if let detailRatio = model.detail?.imageURL == nil ? nil : imageRatio { return detailRatio }
        if let known, known.aspectRatio > 0 { return CGFloat(known.aspectRatio) }
        return 4.0 / 3.0
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(model.detail?.title ?? known?.title ?? "投稿")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await model.load(id: id) }
        .fullScreenCover(isPresented: $showViewer) {
            if let url = model.detail?.imageURL {
                ImageViewerScreen(url: url, title: model.detail?.title ?? "")
            }
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
                            .overlay(RemoteImage(url: detail.authorAvatarURL, contentMode: .fill))
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

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

@MainActor
final class SubmissionViewModel: ObservableObject {
    @Published private(set) var detail: FASubmissionDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

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
            detail = try FASubmissionDetail.parse(html, from: url)
            loadedID = id
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}
