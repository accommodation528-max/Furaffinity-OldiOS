import SwiftUI

/// 屏蔽词管理：加词、删词、看命中效果。
///
/// 没有做成「输入即过滤」的重型界面 —— 这个词表是长期维护的东西，
/// 用户一次加几个词、偶尔删掉，所以用一个普通 List + 顶部输入框最省事。
struct BlocklistScreen: View {

    @ObservedObject private var blocklist = Blocklist.shared
    @State private var draft = ""
    @State private var hint: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("要屏蔽的词，比如 scat", text: $draft)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit { commit() }
                        .accessibilityLabel("要屏蔽的词")
                    Button("添加") { commit() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("添加")
            } footer: {
                Text("命中标题、作者名或任意标签就把这条投稿藏起来（不分大小写，包含即算）。\n写 `dog` 会同时挡住 `doggo` 与 `Dog`；想要精确就把词写长一点。")
            }

            Section {
                if blocklist.words.isEmpty {
                    Text("还没有屏蔽词")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(blocklist.words, id: \.self) { word in
                        HStack {
                            Image(systemName: "nosign")
                                .foregroundColor(.secondary)
                            Text(word)
                            Spacer()
                        }
                    }
                    .onDelete { blocklist.remove(at: $0) }
                }
            } header: {
                Text(blocklist.words.isEmpty ? "词表" : "词表 · \(blocklist.words.count) 条")
            } footer: {
                if blocklist.isActive {
                    Text("左滑删除。改动会让首页 / 浏览 / 搜索 / 画廊重新加载。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("屏蔽词")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 15 的 ToolbarContentBuilder 不支持 if（`buildIf' is only available in iOS 16`），
            // 所以这里是「一直挂着、空表时隐身」，而不是条件插入
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    for word in blocklist.words { blocklist.remove(word) }
                }
                .foregroundColor(.red)
                .opacity(blocklist.words.isEmpty ? 0 : 1)
                .disabled(blocklist.words.isEmpty)
            }
        }
    }

    private func commit() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if blocklist.add(word) {
            hint = "已加入「\(word.lowercased())」，列表会重新加载。"
            draft = ""
        } else {
            hint = "「\(word.lowercased())」已经在词表里了。"
        }
    }
}
