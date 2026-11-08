import SwiftUI
import UIKit
import PDFKit
import FAPages

/// 文本投稿的阅读器。
///
/// FA 上的「故事」没有内联正文：详情页只有一张封面图和 `Download` 链接，
/// 文件是 txt / md / pdf / docx / rtf。所以这里按格式分流：
/// - txt / md（FA 的 `.txt` 其实是 **BBCode**）→ 原生阅读器
/// - pdf → PDFKit
/// - 其余 → 交给系统的「用其他 App 打开」
struct StoryScreen: View {

    let detail: FASubmissionDetail

    var body: some View {
        Group {
            if let url = detail.downloadURL {
                switch FAStoryFormat.from(url) {
                case .plainText, .markdown:
                    StoryTextReader(detail: detail)
                case .pdf:
                    StoryPDFReader(detail: detail)
                default:
                    StoryUnsupported(detail: detail)
                }
            } else {
                StoryMessage(
                    symbol: "doc.questionmark",
                    title: "这条投稿没有可下载的文件",
                    detail: "可能是图片投稿，或者作者关掉了下载。"
                )
            }
        }
        .navigationTitle(detail.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 纯文本 / Markdown

private struct StoryTextReader: View {

    let detail: FASubmissionDetail

    @StateObject private var model = StoryTextModel()
    @State private var fontSize: Double = 17
    @State private var lineSpacing: Double = 5

    @State private var lastIndex = 0
    @State private var restoring = true

    var body: some View {
        Group {
            if let error = model.errorText {
                StoryMessage(symbol: "exclamationmark.triangle", title: "打不开这篇", detail: error)
            } else if model.isLoading {
                ProgressView("正在下载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task { await model.load(detail) }
        .onAppear {
            // 这台机器上 UserDefaults 写不进（见 FAStore 注释），字号/行距也得自己存
            fontSize = FAStore.double("fa.reader.fontSize", default: 17)
            lineSpacing = FAStore.double("fa.reader.lineSpacing", default: 5)
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header

                    ForEach(Array(model.blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block)
                            .id(index)
                            .onAppear { note(index) }
                    }

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            fontSize = min(fontSize + 1, 30)
                            FAStore.set(fontSize, for: "fa.reader.fontSize")
                        } label: { Label("字号加大", systemImage: "textformat.size.larger") }
                        Button {
                            fontSize = max(fontSize - 1, 12)
                            FAStore.set(fontSize, for: "fa.reader.fontSize")
                        } label: { Label("字号减小", systemImage: "textformat.size.smaller") }
                        Button {
                            lineSpacing = lineSpacing > 5 ? 2 : 9
                            FAStore.set(lineSpacing, for: "fa.reader.lineSpacing")
                        } label: {
                            Label(lineSpacing > 5 ? "紧凑行距" : "宽松行距", systemImage: "text.alignleft")
                        }
                        if let progress = model.savedIndex, progress > 0 {
                            Divider()
                            Button { proxy.scrollTo(progress, anchor: .top) } label: {
                                Label("回到上次位置（\(progress + 1)/\(model.blocks.count)）", systemImage: "bookmark")
                            }
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                }
            }
            .onAppear {
                // 注意：不能用 `onChange(of: blocks.count)` 做这件事 —— 内容视图是在
                // 解析完之后才出现的，那时 count 早就是 N 了，onChange 永远不会触发，
                // `restoring` 就一直为 true，进度也就一条都记不下来（踩过）。
                guard restoring else { return }
                restoring = false
                if let saved = model.savedIndex, saved > 0 {
                    // 第一次渲染完再跳：太早跳位置不准（LazyVStack 还没建行）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        proxy.scrollTo(saved, anchor: .top)
                    }
                }
            }
            .onDisappear {
                // 退出时补一次精确位置（滚动过程中只在每 10 块存一次）
                if lastIndex > 0 { StoryProgress.save(lastIndex, for: detail.id) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.title)
                .font(.title2).bold()
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                NavigationLink(destination: UserScreen(slug: detail.authorSlug)) {
                    Text(detail.authorName).font(.subheadline).bold()
                }
                if let posted = detail.postedAt {
                    Text("·").foregroundColor(.secondary)
                    Text(Self.dateFormatter.string(from: posted))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let format = detail.storyFormat {
                    Text(format.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .cornerRadius(4)
                }
            }
            Text("\(model.characterCount) 字")
                .font(.caption2)
                .foregroundColor(.secondary)
            Divider().padding(.top, 4)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            Text("—— 完 ——")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("正文来自作者上传的 \(detail.storyFormat?.displayName ?? "文件")，App 只做了排版，没有改动任何字。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func blockView(_ block: FAStoryBlock) -> some View {
        switch block {
        case .heading(let level, let runs):
            styledText(runs, size: fontSize * (level == 1 ? 1.5 : level == 2 ? 1.28 : 1.12), weight: .semibold)
                .padding(.top, 6)

        case .paragraph(let runs):
            styledText(runs, size: fontSize)

        case .quote(let runs):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                styledText(runs, size: fontSize)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

        case .listItem(let runs):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundColor(.secondary)
                styledText(runs, size: fontSize)
            }

        case .rule:
            Divider().padding(.vertical, 6)
        }
    }

    /// 把一组 run 拼成一个 `Text`（iOS 15 上 `Text + Text` 最稳，不用 AttributedString）
    private func styledText(_ runs: [FAStyledRun], size: Double, weight: Font.Weight = .regular) -> some View {
        var combined = Text("")
        for run in runs {
            // 注意：`Text.italic()` / `underline()` / `strikethrough()` 的无参版本 iOS 13 起就有，
            // 但带 Bool 参数的那几个是 iOS 16 的 View 修饰符，iOS 15 上会直接编译失败 —— 只能 if 拆开。
            var piece = Text(run.text)
                .font(.system(size: run.isSubscript || run.isSuperscript ? size * 0.75 : size,
                              weight: run.bold ? .semibold : weight))
            if run.italic { piece = piece.italic() }
            if run.underline { piece = piece.underline() }
            if run.strikethrough { piece = piece.strikethrough() }
            if let hex = run.colorHex, let color = Color(hex: hex) {
                piece = piece.foregroundColor(color)
            }
            combined = combined + piece
        }
        return combined
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ index: Int) {
        guard !restoring else { return }
        guard index > lastIndex else { return }
        lastIndex = index
        // 每次都记：FAStore 内部有 0.4s 合并，写盘不会跟着滚动频率走
        StoryProgress.save(index, for: detail.id)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
private final class StoryTextModel: ObservableObject {

    @Published var blocks: [FAStoryBlock] = []
    @Published var isLoading = true
    @Published var errorText: String?
    @Published var characterCount = 0
    /// 上次停下的块下标（渲染完再跳，见 StoryTextReader.onChange）
    @Published var savedIndex: Int?

    func load(_ detail: FASubmissionDetail) async {
        guard let url = detail.downloadURL else {
            errorText = "没有下载地址"
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        do {
            let data = try await FAFetch.data(url)
            guard let text = Self.decode(data) else {
                errorText = "文件编码无法识别（\(data.count) 字节）"
                isLoading = false
                return
            }
            let parsed = FABBCode.parse(text)
            blocks = parsed
            characterCount = FABBCode.characterCount(parsed)
            savedIndex = StoryProgress.load(detail.id)
            isLoading = false
        } catch {
            errorText = FAErrorMessage.describe(error)
            isLoading = false
        }
    }

    /// FA 的 txt 是 UTF-8（常带 BOM）；作者从别处贴过来的偶有 Latin-1/CP1252
    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }
}

// MARK: - PDF

private struct StoryPDFReader: View {

    let detail: FASubmissionDetail

    @State private var document: PDFDocument?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let errorText {
                StoryMessage(symbol: "exclamationmark.triangle", title: "打不开这篇 PDF", detail: errorText)
            } else if let document {
                PDFKitView(document: document)
                    .navigationTitle(detail.title)
            } else {
                ProgressView("正在下载 PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = detail.downloadURL else { return }
        do {
            let data = try await FAFetch.data(url)
            // PDFKit 只吃文件 / URL，所以先落到临时目录
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("fa-\(detail.id).pdf")
            try data.write(to: file, options: .atomic)
            guard let pdf = PDFDocument(url: file) else {
                errorText = "不是有效的 PDF（\(data.count) 字节）"
                return
            }
            document = pdf
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}

private struct PDFKitView: UIViewRepresentable {

    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

// MARK: - 其他格式

private struct StoryUnsupported: View {

    let detail: FASubmissionDetail

    @State private var showShare = false

    private var formatName: String {
        detail.storyFormat?.displayName ?? "未知格式"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("这是 \(formatName) 文件")
                .font(.headline)
            Text("App 内只排版纯文本 / Markdown / PDF。\n这种格式可以下载后用系统里的其他 App 打开。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showShare = true
            } label: {
                Label("下载并打开", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.14))
                    .cornerRadius(9)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showShare) {
            StoryShareSheet(detail: detail)
        }
    }
}

/// 下载到临时目录再交给 `UIActivityViewController`（iOS 15 没有 ShareLink）
private struct StoryShareSheet: View {

    let detail: FASubmissionDetail

    @State private var fileURL: URL?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let fileURL {
                ActivityView(items: [fileURL])
            } else if let errorText {
                StoryMessage(symbol: "exclamationmark.triangle", title: "下载失败", detail: errorText)
            } else {
                ProgressView("正在下载…")
            }
        }
        .task {
            guard let url = detail.downloadURL else {
                errorText = "没有下载地址"
                return
            }
            do {
                let data = try await FAFetch.data(url)
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(detail.id)-\(url.lastPathComponent)")
                try data.write(to: target, options: .atomic)
                fileURL = target
            } catch {
                errorText = FAErrorMessage.describe(error)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 公共小件

private struct StoryMessage: View {

    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 阅读进度：按「块下标」记，够用且不需要精确像素
@MainActor
enum StoryProgress {

    private static func key(_ id: Int) -> String { "fa.story.pos.\(id)" }

    static func save(_ index: Int, for id: Int) {
        FAStore.set(index, for: key(id))
    }

    static func load(_ id: Int) -> Int? {
        let value = FAStore.int(key(id), default: 0)
        return value > 0 ? value : nil
    }

    static func clear(_ id: Int) {
        FAStore.remove(key(id))
    }
}

extension Color {

    /// `#rrggbb` / `#rgb` → Color；解析不出来返回 nil（宁可用默认色，不要黑成一片）
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }
}
