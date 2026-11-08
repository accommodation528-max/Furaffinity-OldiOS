import SwiftUI
import FAPages

struct RootView: View {

    @ObservedObject private var host = FAWebHost.shared
    @ObservedObject private var gate = ChallengeGate.shared

    @State private var showLogin = false

    var body: some View {
        ZStack(alignment: .top) {
            // 常驻 WebView 垫在最底下：它必须全尺寸待在 window 里，
            // 才能让 Cloudflare 的挑战脚本正常跑（详见 FAWebHost 的注释）
            FAWebHostView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabView {
                NavigationView { HomeScreen() }
                    .tabItem { Label("首页", systemImage: "house") }

                NavigationView { BrowseScreen() }
                    .tabItem { Label("浏览", systemImage: "square.grid.2x2") }

                NavigationView { SearchScreen() }
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }

                NavigationView { AccountScreen(showLogin: $showLogin) }
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
            }
            .accentColor(.orange)   // iOS 15 用 accentColor，不是 tint

            if gate.isSolving {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在通过 Cloudflare 验证…").font(.footnote)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .onAppear {
            // 冷启动先让 WebView 跑一遍首页续信任；顺手把登录态刷进界面
            Task { await FAWebHost.shared.warmUpIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .faiosLoginDidChange)) { _ in
            // 登录态变化后，列表里的旧结果（比如 NSFW 的 Login Required）要能重来
            Task { await FAWebHost.shared.syncCookies() }
        }
        .sheet(isPresented: $showLogin) {
            FALoginView()
        }
    }
}

// MARK: - 屏幕

struct HomeScreen: View {
    var body: some View {
        BrowseScreen(startURL: FAURLs.home, title: "FurAffinity")
    }
}

struct BrowsePlaceholder: View {
    var body: some View {
        PlaceholderScreen(
            title: "浏览",
            symbol: "square.grid.2x2",
            message: "排序 · 时间范围 · 类型 · 分级"
        )
        .navigationTitle("浏览")
    }
}

struct SearchPlaceholder: View {
    var body: some View {
        PlaceholderScreen(
            title: "搜索",
            symbol: "magnifyingglass",
            message: "支持标签、作者、多个条件组合"
        )
        .navigationTitle("搜索")
    }
}

struct AccountScreen: View {

    @Binding var showLogin: Bool

    @ObservedObject private var host = FAWebHost.shared
    @State private var checkMessage: String?

    var body: some View {
        List {
            Section {
                if host.isLoggedIn {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 34))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已登录").font(.headline)
                            Text("cookie 已存入 Keychain（本机专用，不进 iCloud）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("重新登录")
                        }
                    }
                    Button {
                        logout()
                    } label: {
                        Text("退出登录").foregroundColor(.red)
                    }
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle")
                            Text("登录 FurAffinity")
                        }
                    }
                }
            } header: {
                Text("账号")
            } footer: {
                Text("登录在应用内的网页里完成，Cloudflare 的人机验证也由它承担 —— 账号密码不经过本 App。")
            }

            Section {
                Button {
                    Task { await refreshTrust() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(host.isRefreshing ? "正在刷新…" : "刷新 Cloudflare 信任")
                    }
                }
                .disabled(host.isRefreshing)

                Button {
                    Task { await runHealthCheck() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                        Text("自检登录态")
                    }
                }
                // 注意：别在这上面挂 .simultaneousGesture(LongPressGesture) ——
                // Button 在 List 里被同时喂了一个长按手势后，单击会一起哑掉（真机上就是这个症状）

                Button {
                    Task { await runHealthCheck(forceChallenge: true) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.shield")
                        Text("自检（强制挑战）")
                    }
                }

                if let message = checkMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("连接")
            } footer: {
                Text("被 Cloudflare 拦下时点「刷新信任」：会用内嵌网页重新过一遍验证，然后重开连接。")
            }

            Section("关于") {
                // LabeledContent 是 iOS 16+，这里手搓
                HStack {
                    Text("版本")
                    Spacer()
                    Text(BuildInfo.version).foregroundColor(.secondary)
                }
                HStack {
                    Text("解析层")
                    Spacer()
                    Text("FAPages").foregroundColor(.secondary)
                }
                HStack {
                    Text("部署目标")
                    Spacer()
                    Text("iOS 15").foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的")
        .onReceive(NotificationCenter.default.publisher(for: .faiosLoginDidChange)) { _ in
            // 登录/退出后旧的检查结论一律作废，否则会留着「未登录」这种过期文案
            checkMessage = nil
        }
    }

    private func logout() {
        Task {
            await FAWebHost.shared.clearCookies()
            checkMessage = "已清除登录信息"
        }
    }

    private func refreshTrust() async {
        checkMessage = nil
        await FAWebHost.shared.warmUpIfNeeded(force: true)
        checkMessage = host.isLoggedIn ? "已完成，登录态有效" : "已完成（当前为访客身份）"
    }

    private func runHealthCheck(forceChallenge: Bool = false) async {
        checkMessage = forceChallenge ? "检查中（先制造一次挑战）…" : "检查中…"
        checkMessage = await FAHealthCheck.run(forceChallenge: forceChallenge)
    }
}

struct PlaceholderScreen: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("M0 骨架 · iOS 15")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding(32)
    }
}

enum BuildInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}
