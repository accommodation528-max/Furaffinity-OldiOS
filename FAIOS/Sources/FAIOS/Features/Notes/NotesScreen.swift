import SwiftUI
import FAPages

/// 私信（Notes）收件箱：`/msg/pms/`。
///
/// 与通知页的区别：私信有「未读」状态、能回信，所以每行带一个小圆点，
/// 右上角有「写私信」。
struct NotesScreen: View {

    @StateObject private var model = NotesViewModel()
    @State private var showingCompose = false
    @State private var composeRecipient = ""
    @State private var refreshToken = 0

    var body: some View {
        Group {
            if model.isLoading && model.notes.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
            } else if let error = model.errorText, model.notes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "envelope.badge").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(error).font(.footnote).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button("重试") { Task { await model.reload() } }.font(.footnote)
                }
                .padding(.top, 60)
            } else if model.notes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundColor(.secondary)
                    Text("没有私信").font(.footnote).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                List {
                    ForEach(model.notes) { note in
                        NavigationLink(destination: NoteThreadScreen(
                            url: note.url,
                            fallbackSubject: note.subject,
                            onReplied: { refreshToken += 1 }
                        )) {
                            row(note)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.reload() }
                .id(refreshToken)
            }
        }
        .navigationTitle("私信")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    composeRecipient = ""
                    showingCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showingCompose) {
            NavigationView {
                ComposeNoteScreen(recipient: composeRecipient, replyKey: nil, subject: "", onSent: {
                    Task { await model.reload() }
                })
            }
        }
        .task { await model.load() }
    }

    private func row(_ note: FANoteSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(note.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(note.subject.isEmpty ? "（无标题）" : note.subject)
                    .font(.subheadline)
                    .fontWeight(note.isUnread ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(note.authorName.isEmpty ? "（已注销用户）" : note.authorName)
                        .font(.caption2).foregroundColor(.secondary)
                    if let sent = note.sentAt {
                        Text("· " + FAFormat.relative(sent))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
final class NotesViewModel: ObservableObject {

    @Published private(set) var notes: [FANoteSummary] = []
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
            let url = FAURLs.notesInbox
            let html = try await FAFetch.html(url)
            notes = try FANotes.list(html, from: url)
            loaded = true
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}

// MARK: - 单封私信

struct NoteThreadScreen: View {

    let url: URL
    let fallbackSubject: String
    var onReplied: (() -> Void)? = nil

    @StateObject private var model = NoteThreadViewModel()
    @State private var replying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let note = model.note {
                    Text(note.subject.isEmpty ? fallbackSubject : note.subject)
                        .font(.title3).bold()
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if !note.authorSlug.isEmpty {
                            NavigationLink(destination: UserScreen(slug: note.authorSlug)) {
                                Text(note.authorName).font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(note.authorName).font(.subheadline)
                        }
                        Spacer()
                        if let sent = note.sentAt {
                            Text(FAFormat.dateTime(sent)).font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    Text(note.bodyText)
                        .font(.callout)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Button {
                        replying = true
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.footnote)
                    }
                    .disabled(note.replyKey == nil)
                    .padding(.top, 6)
                } else if model.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
                } else if let error = model.errorText {
                    Text(error).font(.footnote).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 70)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("私信")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(url: url) }
        .sheet(isPresented: $replying) {
            NavigationView {
                ComposeNoteScreen(
                    recipient: model.note?.authorSlug ?? "",
                    replyKey: model.note?.replyKey,
                    subject: "Re: " + (model.note?.subject ?? fallbackSubject),
                    onSent: {
                        onReplied?()
                    }
                )
            }
        }
    }
}

@MainActor
final class NoteThreadViewModel: ObservableObject {

    @Published private(set) var note: FANote?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private var loadedURL: URL?

    func load(url: URL) async {
        guard loadedURL != url else { return }
        loadedURL = url
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let html = try await FAFetch.html(url)
            note = try FANotes.note(html, from: url)
        } catch {
            errorText = FAErrorMessage.describe(error)
        }
    }
}

// MARK: - 写私信 / 回信

/// 发私信 / 回信。
///
/// 原生表单只负责收集内容；真正的发送交给 `ComposeNoteWebView` ——
/// 因为 FA 的写信页挂着 Cloudflare Turnstile，纯 URLSession POST 会被
/// 「CAPTCHA verification failed」打回来（实测见 FANotes.requiresCaptcha 的注释）。
struct ComposeNoteScreen: View {

    let recipient: String
    let replyKey: String?
    let subject: String
    var onSent: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var to: String = ""
    @State private var title: String = ""
    @State private var message: String = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var showingWeb = false

    var body: some View {
        Form {
            Section {
                TextField("收信人（用户名）", text: $to)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("主题", text: $title)
            }
            Section(header: Text("内容")) {
                TextEditor(text: $message)
                    .frame(minHeight: 160)
            }
            if let errorText {
                Section {
                    Text(errorText).font(.footnote).foregroundColor(.red)
                }
            }
            Section {
                Button {
                    errorText = nil
                    sending = true
                    showingWeb = true
                } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView() } else { Text("发送") }
                        Spacer()
                    }
                }
                .disabled(sending || to.isEmpty || title.isEmpty || message.isEmpty)
            }
        }
        .navigationTitle("写私信")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
            }
        }
        .sheet(isPresented: $showingWeb) {
            ComposeNoteWebView(
                recipient: to.trimmingCharacters(in: .whitespaces),
                subject: title,
                message: message
            ) { ok, error in
                sending = false
                if ok {
                    onSent?()
                    dismiss()
                } else if let error, error != "已取消" {
                    errorText = error
                }
            }
        }
        .onAppear {
            if to.isEmpty { to = recipient }
            if title.isEmpty { title = subject }
        }
    }
}
