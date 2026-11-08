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
            // 音乐播放条：贴在 TabBar 上方，切 tab 也能继续控制
            .safeAreaInset(edge: .bottom) {
                MiniPlayerBar()
            }

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
            // 冷启动先把 Keychain 里的会话注回 WKWebView —— 否则 WebView 是未登录身份，
            // 「续 Cloudflare 信任」用的就是访客，白跑一趟。
            Task {
                await FAWebCookieBridge.injectStoredCookies()
                // 让出一段时间再跑预热：首页首屏要抢带宽，冷启动时 WebView 同步加载
                // FA 首页（100+ KB + 一堆图标）会把第一屏图片挤在后面。
                // 实测：cf_clearance 不是必需项（有 a/b 就够），所以晚 2.5 秒开跑没有风险。
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await FAWebHost.shared.warmUpIfNeeded()
            }
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
    @ObservedObject private var filter = ContentFilter.shared
    @ObservedObject private var account = FAAccountStore.shared
    @State private var checkMessage: String?
    @State private var imageStats: FAImageCache.Stats?
    @State private var storeMessage: String?
    /// 开发者工具默认收起（日常用不到，展开才有噪音）
    @State private var showDiagnostics = false

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

                // 开发者工具默认折叠：日常使用时这一堆「（调试）」行只会造成噪音
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    Button {
                        Task { await runHealthCheck(forceChallenge: true) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.shield")
                            Text("自检（强制挑战）")
                        }
                    }

                    // 真机是唯一有登录态的机器，把需要登录的页面抓到可写目录里，
                    // 再用 SSH 拉回 PC 当解析层的真实 fixture（离线就能写测试）
                    Button {
                        Task { await exportSnapshots() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up.on.square")
                            Text("导出页面快照")
                        }
                    }

                    // 一条 .txt 故事（正文是 BBCode 的那种），用来验证阅读器
                    NavigationLink(destination: SubmissionScreen(id: 66961612)) {
                        HStack(spacing: 10) {
                            Image(systemName: "book")
                            Text("故事样本")
                        }
                    }

                    // 一条音乐投稿（验证播放器与锁屏控制）
                    NavigationLink(destination: SubmissionScreen(id: 66961793)) {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note")
                            Text("音乐样本")
                        }
                    }

                    // 设置到底写没写进磁盘（这台机器上 UserDefaults 是假的）
                    Button {
                        storeMessage = FAStore.filePath.map { path in
                            let error = FAStore.lastWriteError.map { "｜写盘错误：\($0)" } ?? "｜写盘 OK"
                            return "设置：\(path)\(error)"
                        } ?? "设置：找不到可写目录（只存在内存里）"
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive")
                            Text("设置存储位置")
                        }
                    }

                    if let storeMessage {
                        Text(storeMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                        .font(.subheadline)
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

            // 图片管线的现场读数：真机上唯一能看到的「缓存到底有没有生效」
            Section {
                Button {
                    Task { await refreshImageStats() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("刷新图片缓存统计")
                    }
                }

                if let stats = imageStats {
                    Text(stats.summary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(role: .destructive) {
                    Task {
                        await FAImageCache.shared.clear()
                        await refreshImageStats()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                        Text("清空图片缓存")
                    }
                }
            } header: {
                Text("图片")
            } footer: {
                Text("缩略图按格子大小降采样后再解码，原图只喂给查看器。磁盘缓存 320MB，超了按最旧删除。")
            }

            // 登录后才有的入口：关注流 / 通知 / 我的收藏
            if host.isLoggedIn {
                Section {
                    NavigationLink(destination: BrowseScreen(startURL: FAURLs.msgSubmissions, title: "关注流")) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.circle")
                            Text("关注流")
                        }
                    }
                    NavigationLink(destination: NotificationsScreen()) {
                        HStack(spacing: 10) {
                            Image(systemName: "bell")
                            Text("通知")
                        }
                    }
                    NavigationLink(destination: NotesScreen()) {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope")
                            Text("私信")
                        }
                    }
                    if let favorites = account.favoritesURL {
                        NavigationLink(destination: BrowseScreen(startURL: favorites, title: "我的收藏")) {
                            HStack(spacing: 10) {
                                Image(systemName: "heart")
                                Text("我的收藏")
                            }
                        }
                    }
                } header: {
                    Text("我的内容")
                } footer: {
                    Text(account.slug.map { "以 @\($0) 的身份浏览。" } ?? "正在获取你的用户名…")
                }
            }

            Section {
                Picker(selection: $filter.mode) {
                    ForEach(ContentFilter.Mode.allCases) { mode in
                        HStack(spacing: 8) {
                            Image(systemName: mode.symbol)
                            Text(mode.title)
                        }
                        .tag(mode)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: filter.mode.symbol)
                        Text("内容分级")
                    }
                }

                HStack {
                    Text("当前")
                    Spacer()
                    Text(filter.mode.detail).foregroundColor(.secondary)
                }
            } header: {
                Text("内容")
            } footer: {
                Text("列表里按投稿的分级过滤：General 全年龄、Mature 成人向、Adult 露骨。切换后首页/浏览/搜索/画廊会重新拉取。")
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
        .task(id: host.isLoggedIn) {
            // 登录后要知道「我是谁」，才能给出收藏页入口
            await FAAccountStore.shared.refreshIfNeeded(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .faiosLoginDidChange)) { _ in
            // 登录/退出后旧的检查结论一律作废，否则会留着「未登录」这种过期文案
            checkMessage = nil
            Task {
                if FACookieStore.shared.isLoggedIn {
                    await FAAccountStore.shared.refreshIfNeeded(force: true)
                } else {
                    FAAccountStore.shared.clear()
                }
            }
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

    private func refreshImageStats() async {
        imageStats = await FAImageCache.shared.snapshot()
    }

    private func runHealthCheck(forceChallenge: Bool = false) async {
        checkMessage = forceChallenge ? "检查中（先制造一次挑战）…" : "检查中…"
        checkMessage = await FAHealthCheck.run(forceChallenge: forceChallenge)
    }

    /// 把「只有登录后才看得出结构」的页面各抓一份，落到可写目录，SSH 取回当 fixture
    private func exportSnapshots() async {
        checkMessage = "导出中（每页约 1 秒）…"
        let requests: [(String, URL)] = [
            ("detail", FAURLs.submission(66962944)),
            ("msg-others", FAURLs.msgNotifications),
            ("msg-submissions", FAURLs.msgSubmissions),
            ("pms", FAURLs.notesInbox),
            ("pms-sent", FAURLs.notesSent),
            ("pms-archive", URL(string: "https://www.furaffinity.net/msg/pms/archive/")!),
            ("newpm", URL(string: "https://www.furaffinity.net/newpm/nosense528/")!),
            ("journal", FAURLs.journal(11447701)),
            ("controls", FAURLs.controls),
        ]
        checkMessage = await FADiag.exportPages(requests)
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
