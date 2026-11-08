# FAIOS — FurAffinity 第三方 iOS 客户端（iOS 15+ / SwiftUI）

> **v2（已按决策更新）**：本地 xtool 构建 · 目标设备 iOS 15 + TrollStore · 首版做完整版
> 目标：看图、看艺术家、看小说（story / journal）的**原生 SwiftUI** 客户端，最低 iOS 15。
>
> **关键参考项目：<https://github.com/Ceylo/FurAffinityApp>**（47★，SwiftUI，2026-11-01 仍在更新）
> 它把 FA 客户端的**全部硬骨头**都啃过了（Cloudflare、解析、阅读器、通知、Notes），
> 但 `IPHONEOS_DEPLOYMENT_TARGET = 26.5` —— 我们要做的是**把这套设计降到 iOS 15**。
> ⚠️ 该仓库**没有 LICENSE**（默认版权保留）：只能读架构/选择器/踩坑记录，**不能复制代码**。

---

## 1. 参考项目拆解（我们要"借"什么）

### 1.1 它的模块划分 = 我们的目标分层

| 模块 | 内容 | 我们是否采用 |
|---|---|---|
| `FAPages` | **纯解析层**：HTML → Swift 结构体，只依赖 SwiftSoup + OrderedCollections | ✅ 完全照搬这个分层 |
| `FAKit` | 高层 API：会话、HTTP、图片、RichText、主题 | ✅ 精简后采用 |
| `FurAffinity` | SwiftUI App（iOS 26 专用：Liquid Glass、`@Observable`） | ❌ 全部重写为 iOS 15 |
| `Android` | Skip（Swift→Kotlin 转译） | ❌ 与我们无关，跳过 |
| `FALogging` | 本地 SwiftPM 包，全局 logging | ✅ 可用同名自研替代 |

依赖清单（都可上 iOS 15）：
`SwiftSoup 2.7.5`（HTML 解析）· `Cache 7.4`（内存+磁盘缓存）· `swift-collections`（OrderedDictionary）· `ZIPFoundation`（docx）· `SwiftGraph`（仅注释树用，可省）

### 1.2 解析器选择器字典（实测有效，直接可用）

```swift
// 投稿详情
"div.submission-area img#submissionImg"        // [data-preview-src] / [data-fullview-src]
"div.submission-content-inner div#submission-options a.button"
    // text ∈ {"+Fav", "-Fav"}；**href 就是收藏 URL，自带 token** → 收藏不需要逆向！
"div div.submission-content-stats"             // > span[0] 分类名，> span[1] 值
"div.submission-area.submission-writing"       // 判断是否为小说/文章
"div.submission-area.submission-music audio#c-musicPlayer_inner"  // [src]
a 文本为 "Download" 的节点                      // 小说原文件（txt/md/docx/pdf/rtf）

// 评论
"div.comments-list div#comments-submission div.comment_container"
"div.comments-list div#responsebox"            // 回复框；文本含 "disabled" 表示禁评

// 列表页（首页/浏览/搜索/画廊通用）
"figure"                                        // [id] = "sid-66962568"，[class] 含 r-general/mature/adult
"figure b u a img"                              // [src] 缩略图，[data-width]/[data-height]
"figcaption p a"                                // [0]=标题，[1]=作者（[href] 是用户页）
带 "Prev" / "Next" 文本的 button 的 [href]        // 分页（不使用 page=N 猜）

// 用户页
"body div#main-window" → "div#site-content userpage-nav-header"
"a.c-usernameBlock__displayName"  // 显示名；[href] 是用户名
"div#header a img"                 // banner
"userpage-nav-interface-buttons a.button"  // 关注按钮，[href] 即 watch URL
```

> **重要修正**：v1 里「收藏/关注需要逆向」的风险（R3）**解除**——它们就是普通 `<a>` 链接，URL 里带一次性 token，GET 即可。风险等级从「高」降到「低」。

### 1.3 Cloudflare 的完整解法（这是本项目最有价值的部分）

参考项目在 `Android/docs/cloudflare-and-login.md` 里写了实测结论，几乎可以直接照搬设计：

1. **`cf_clearance` 与 User-Agent 逐字节绑定** → App 内 **WKWebView 与 URLSession 必须用完全相同的 UA**。建议 UA 尾部带 `FAiOS/0.1` 标识（FA 员工靠这个识别第三方客户端流量）。
2. **常驻一个"全尺寸、被不透明背景遮住"的 WKWebView**，启动后加载一次 FA 首页。作用不是登录，而是**续 Cloudflare 信任**。
   - 不能用 1×1 尺寸：viewport 只有 4 CSS px，Turnstile 容器会塌成 0×69，被动挑战永远过不去。
   - 代价：每次启动多加载一次首页（含广告）。
3. **挑战分两级**：被动（无 UI，1.5–3 秒自动过，绝大多数情况）/ 交互（才弹 sheet 给用户点）。判定依据是 `_cf_chl_opt.cType == "interactive"`，**不是**勾选框的 iframe（它在 closed shadow root 里，抓不到）。
4. **修复顺序（不能改）**：
   `淘汰现有连接` → `awaitResolution()` → `再淘汰一次` → **只重试一次** → 仍失败才退化到「WebView 导航 + 读 DOM」。
   理由：Cloudflare 判定的是**连接**而不是请求，盲重试是浪费；solve 期间新开的连接带的是旧 clearance。
5. **同一时刻只允许一次 WebView 导航**（全局串行队列），否则两次导航交错会读到对方的页面 → 解析出错误数据。
6. 一个请求被挑战后**不要**把挑战页交给解析器，先在原地等挑战过去再重试。

### 1.4 小说/文章的形态（比 v1 的假设更复杂）

FA 的 story 投稿不是一个富文本页面，而是：
- 页面里有一个 **Download 链接**指向原始文件：`.txt` / `.md` / `.docx` / `.pdf` / `.rtf`
- 参考项目的做法：`StoryReaderView.Content.load(data:filename:documentUrl:)` 按扩展名分流
  - txt / md → 逐行 `Text`，放 `LazyVStack`（**不能一次性测量整本小说**）
  - docx → `ZIPFoundation` 解包 + `DocxTextParser`
  - pdf / rtf → `PDFReflow`（38KB 的重排引擎，把 PDF 文本流重排成可分页文本）
- Android 端直接放弃 pdf/docx 重排，改为「用其他 App 打开」——**这是一个合理的降级选项**

---

## 2. 我们的产品范围（首版 = 完整版）

### 屏幕清单（对齐参考项目 `screens.md`）
| 屏幕 | 内容 | 难度 |
|---|---|---|
| 未登录首页 | Featured / 最新投稿 / 最新文章 / 音乐 / 手作 + 登录入口 | ★ |
| 关注流（Followed feed） | 登录后：watched 用户的新投稿，按 sid 递减分页 | ★★ |
| 浏览 / 搜索 | 排序、时间范围、类型、分级；瀑布流 | ★★ |
| 投稿详情 | 大图、标题、作者、统计、简介（BBCode→富文本）、标签、评论树 | ★★★ |
| 图片查看器 | 单击切换 fill/fit、捏合缩放、下拉关闭、左右翻页、保存/分享 | ★★★★ |
| 小说阅读器 | 字号/行距/主题/进度记忆/离线；txt/md 原生，docx/pdf 视情况 | ★★★★ |
| 音乐投稿 | 封面 + 系统播放器（AVPlayer） | ★★ |
| 艺术家页 | banner、统计、简介、画廊/Scraps/Favorites、Journals、Shouts、关注按钮 | ★★ |
| 通知 | submissions / watches / comments / journals / favorites 分类 | ★★★ |
| Notes 私信 | 收件箱/已发/归档/废纸篓 + 阅读 + 新建 | ★★★ |
| 收藏/关注 | 就是 GET 那个带 token 的 URL | ★ |
| 设置 | 登录/登出、NSFW 分级、缓存、主题、关于 | ★ |

### 明确不做
上传投稿 / 编辑资料 / 发 Journal / 全站爬取 / 批量下载

---

## 3. 技术架构（iOS 15 版）

```
Sources/
├── FAPages/                    # 纯解析，零 UI 依赖（可单独测试）
│   ├── FAURLs.swift            # 所有端点集中一处
│   ├── FASubmissionPage.swift  FAUserPage.swift  FAHomePage.swift
│   ├── FASubmissionsPage.swift FASearchPage.swift  FASearchQuery.swift
│   ├── FAJournalPage.swift     FANotificationsPage.swift  FANotesPage.swift
│   ├── FAWatchlistPage.swift   FAPageComment.swift  FASystemErrorPage.swift
│   └── data/                   # fixture：抓下来的真实 HTML，回归测试用
└── FAIOS/
    ├── App/          FAIOSApp, RootView, AppState, ScenePhase
    ├── Core/
    │   ├── Net/      FAHTTP (actor), AsyncSemaphore, Backoff, UA 常量
    │   ├── Web/      FAWebSession (常驻隐藏 WKWebView), ChallengeCoordinator
    │   ├── Auth/     CookieStore (Keychain), FALoginView (WKWebView sheet)
    │   ├── RichText/ FAHTMLNormalizer, CSSInliner, AttributedString+FA
    │   └── Design/   FATheme, 字体, 配色
    ├── Data/
    │   ├── Images/   ImagePipeline (两级缓存 + 降采样), DynamicThumbnail
    │   ├── Cache/    DiskCache (Cache 库 or 自写)
    │   └── Story/    StoryText, DocxTextParser, PDFReflow(可选)
    └── Features/     Home Browse Search Submission Viewer Reader User Notifications Notes Settings
```

### 3.1 网络双通道（照搬参考项目的结论）

```swift
// 快路径
actor FAHTTP {
    // URLSession + URLCache + 限流(并发 3 / 间隔 350ms) + 指数退避
    // 每个请求先带上 cookie header（含 cf_clearance）
    // 收到 403 + 挑战特征 → 抛 ChallengeRequired
}

// 慢路径（救援 + 续信任）
@MainActor final class FAWebSession {
    // 常驻隐藏 WKWebView（全尺寸、被背景遮住）
    // func fetchPageHTML(_ url:) async throws -> String   // 串行队列，导航 + 读 DOM
    // func awaitResolution() async                        // 等被动挑战过去
}
```

一次请求的完整生命周期：
```
FAHTTP.get → 403/challenge
  → 淘汰连接 → FAWebSession.awaitResolution() → 淘汰连接
  → 同一请求重试 1 次（新 cookie header）
  → 仍失败 → FAWebSession.fetchPageHTML() 读 DOM 交给解析器
```

### 3.2 iOS 15 降级对照表

| 参考项目（iOS 26） | 我们（iOS 15） |
|---|---|
| `@Observable` / `@State` 新语义 | `ObservableObject` + `@Published` + `@StateObject` |
| `NavigationStack` + `@State var path` | `NavigationView` + 自维护 `NavigationPath` 数组（用一个 `@Published var route: [Route]` 手动 push/pop） |
| Liquid Glass / `.glassEffect` | 纯 SwiftUI `Material` + 自绘卡片 |
| `.scrollPosition` / `.onScrollGeometryChange` | `GeometryReader` + `PreferenceKey` 手写 |
| `SwiftData` | `Codable` + `FileManager` / 轻量 SQLite |
| `.symbolEffect` / `ContentUnavailableView` | 自绘空态视图 |
| `ShareLink` | `UIActivityViewController` 包装 |
| `AsyncImage` | **自写 ImagePipeline**（AsyncImage 无缓存、不可取消、大图爆内存） |
| Swift 6 严格并发默认开启 | `-swift-version 6` 可开，但第三方（SwiftSoup）会有 Sendable 告警 → 用 `@preconcurrency import` |
| 26.5 部署目标 | **15.0**，条件编译 `#available(iOS 16, *)` 留给新 API |

---

## 4. 构建与分发（已选：本地 xtool + WSL，设备有 TrollStore）

### 4.1 为什么 TrollStore 让这件事简单一大截
TrollStore 安装时不校验签名（走 CoreTrust 漏洞），所以：
- **不需要 Apple ID、不需要开发者账号、不需要 7 天续签**
- 只要产出 `.app`（甚至不签名，ad-hoc 签一下即可）→ 打包成 `.ipa` → AirDrop/文件 App 丢进手机 → TrollStore 里安装
- 这意味着我们可以**完全跳过** xtool 的 `auth` 步骤（登录 Apple 账号），只做「编译 + 打包」

### 4.2 ✅ 链路已验证跑通（2026-11-07，本机实测）

> 原本以为要先装 Swift + 下载 7GB 的 Xcode.xip，实测发现 **WSL 里早就装好了**，
> 而且 `xtool dev build` 能直接把 `.iOS(.v15)` 的工程编译成 `MinimumOSVersion = 15.0` 的 ipa。

现有环境（`~/HelloXT` 已有可用的 hello-world 工程，直接克隆即可起新项目）：

```
Swift 6.4.1 (x86_64-unknown-linux-gnu)   → /opt/swift-6.4.1
xtool                                    → /usr/local/bin/xtool（unversioned，但可用）
Darwin SDK（swift sdk list → "darwin"）  → ~/.swiftpm/swift-sdks/darwin.artifactbundle（3.2 GB）
usbmuxd / idevice_id                     → 已装（ideviceinstaller 未装）
```

**决定性验证**（`~/T15`，HelloXT 副本把 `.iOS(.v17)` 改成 `.iOS(.v15)`）：

```
$ sed -i 's/\.iOS(\.v17)/.iOS(.v15)/' Package.swift
$ xtool dev build --ipa
Build complete! (48.96 secs)
Wrote to /root/T15/xtool/HelloXT.ipa          # 115 KB
$ plutil → MinimumOSVersion = 15.0            # ✅ 部署目标确实是 15.0
```

**编译期护栏也验证了**——写一个 `NavigationStack`（iOS 16+）会立刻报错：

```
error: 'NavigationStack' is only available in iOS 16.0 or newer
```

> 这意味着「iOS 15 兼容」不是靠自觉，而是**编译器强制**的。写错 API 根本编不过去。
> 反过来，`if #available(iOS 16, *)` 包裹的新 API 可以正常使用。

### 4.3 构建 → 装机 的实际命令

```bash
# 新工程从 HelloXT 克隆（xtool 对目录结构有要求，别手搓）
cp -r ~/HelloXT ~/FAIOS && cd ~/FAIOS
# 改 Package.swift: platforms: [.iOS(.v15)]，products 只留一个 library
# 改 xtool.yml: bundleID: app.faios.client
xtool dev build --ipa          # → xtool/FAIOS.ipa
cp xtool/FAIOS.ipa /mnt/d/faios/build/
```

**装机（不需要 WSL 连 USB）**：`xtool devices` 在 WSL 里超时（USB 未直通，需要 usbipd）。
但 TrollStore 根本不需要数据线，两条免 USB 路径：
1. 把 ipa 放进 iCloud Drive / 文件 App → 在手机上点它 → 分享给 TrollStore
2. Windows 起一个 HTTP 服务 → 手机 Safari 下载 → 分享给 TrollStore（或 TrollStore 的 Install from URL）

> ⚠️ 注意 `TARGETED_DEVICE_FAMILY` / 图标 / 启动屏还需在 `.app` 里补 `Assets.car` 或 `Info.plist` 键值，TrollStore 才能显示正常图标。

> 编译器版本：本机 Swift **6.4.1** 与 xtool 要求的 6.4 一致，但工程的
> `// swift-tools-version` 仍写 `6.0`（HelloXT 的写法），这样不会强制开启 Swift 6 严格并发，
> 便于混用 SwiftSoup 这类老库。**不要**为了「现代化」把它改成 6.4。

---

## 5. 里程碑（完整版）

| 阶段 | 交付物 | 估时 |
|---|---|---|
| ~~**M0 基础设施**~~ ✅ | WSL+Swift+xtool 打通；SwiftPM 双包工程；`FAHTTP` + UA + 限流；`FAPages` 列表解析器 + 22 测试；端到端验证屏；`build/FAIOS.ipa` 2.27MB / minOS 15.0 | ~~3–4 天~~ 已完成 |
| **M1 只读核心** | ✅ 首页 / 浏览 / 搜索 / 投稿详情 / 图片查看器 / 艺术家页；无限滚动；37 个 fixture 回归测试；**逐屏真机验收通过**（估 6–8 天，实际 1 天） | ~~6–8 天~~ 已完成 |
| **M2 Cloudflare 与会话** | ✅ 常驻 WebView + 登录 sheet（密码不经过 App）+ Keychain cookie + 挑战修复链路；实测 cf_clearance 非必需（有 a/b 就够） | ~~4–5 天~~ 已完成 |
| **M3 账号功能** | ✅ 关注流 / 收藏 / 关注 / 评论（只读）/ 通知 / 我的收藏 / **Notes（私信，走 WebView 过 Turnstile）** / Journal 阅读器；55 测试 | ~~4–5 天~~ 已完成 |
| **性能与图片缓存** | ✅ 两级缓存 + ImageIO 解码期降采样 + 静态资源独立车道；真机：重进页面省 53–59% 网络，首屏出图 4.2s 量级 → ~1s | 1 天（插单） |
| **M4 阅读器** ✅ | 小说阅读器（txt/md → BBCode 原生排版，pdf → PDFKit，docx/rtf → 系统打开）、字号/行距、进度记忆；Journal 阅读器同批完成 | 4–6 天 |
| **M5 打磨发布** | 主题、空态/错误态、无障碍、图标、TrollStore 打包 | 3–4 天 |
| **合计** | | **24–32 人天** |

> 顺序建议：M0 → M1（先能看）→ **M2**（没有它，NSFW/收藏/通知全都做不了）→ M3 → M4。
> 与 v1 不同的是：M2 的难度被参考项目大幅降低（结论已给），但实现量仍在。

---

## 6. 风险登记册（v2）

| ID | 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|---|
| R1 | FA 改版导致选择器全废 | 中 | 高 | 解析层独立 + fixture 回归测试；关注参考项目 commit（他们修得最快） |
| R2 | Cloudflare 策略升级 | 中 | 高 | 常驻 WebView 方案已是社区最优解；UA 固定；不并发轰炸 |
| R3 | ~~收藏需逆向~~ | — | — | **已解除**：收藏/关注就是带 token 的 GET 链接 |
| R4 | FA 限速 | 高 | 中 | 并发 3、间隔 350ms、退避、页面缓存 60s |
| R5 | 2GB 内存设备 + 大图 | 高 | 高 | 强制降采样、滚动取消、内存警告清缓存、`LazyVStack` |
| R6 | ~~无 Mac 的编译链路~~ | — | — | **已解除（实测）**：WSL 里 Swift 6.4.1 + xtool + darwin SDK 已就绪，`.iOS(.v15)` 编出 `MinimumOSVersion = 15.0`，16+ API 编译期即报错；**装机也已打通**（SSH + ldid + uicache → 真机运行） |
| R6b | 图片全被 Cloudflare 403 | 确定 | 中 | **已解决**：`AsyncImage` 走 shared session 必败；统一用 `RemoteImage`（走 `FAHTTP` 的 UA/cookie+cache） |
| R7 | 参考项目无 LICENSE | 确定 | 中 | 只学设计与选择器，代码全部自己写；不引入其仓库文件 |
| R8 | docx/pdf 重排工作量大 | 中 | 中 | 第一版只做 txt/md 原生 + "用 QuickLook 打开" 降级 |

---

## 7. 下一步

**已完成（2026-11-07 实测）**
1. ~~验证链路~~ ✅ WSL 里 Swift 6.4.1 + xtool + darwin SDK 全部现成，`.iOS(.v15)` → `MinimumOSVersion = 15.0` 通过。
2. ~~确认 SDK 版本~~ ✅ 不需要下载 Xcode.xip，`darwin` SDK 已在 `~/.swiftpm/swift-sdks/`。
3. ✅ 产物已放到 `D:\faios\build\HelloXT15.ipa`（115 KB，可做装机验证）。

**M0 已完成并上真机（2026-11-07）**
3. ✅ 产物：`D:\faios\build\HelloXT15.ipa`（115 KB，链路验证用）、`D:\faios\build\FAIOS.ipa`（2.34 MB，真工程）
4. ✅ 工程骨架：`FAPages`（纯解析，Linux 可测）+ `FAIOS`（xtool App），两份 `Package.swift` 均 `platforms: [.iOS(.v15)]` + `swiftLanguageModes: [.v5]`
5. ✅ fixture：browse / home / submission / user / login 五份真实页面快照（`FAPages/Tests/FAPagesTests/Fixtures/`）
6. ✅ `FAHTTP` 骨架：UA、自管 cookie、并发 3 / 间隔 350ms、挑战检测（只检测不修复，修复在 M2）
7. ✅ 图片管线 `RemoteImage`：自管缓存 / 去重 / 失败原因上屏
8. ✅ **真机验证通过**：iPhone 7 Plus / iOS 15.8.3（Dopamine rootless），SSH 推包 → `ldid -S` → `/var/jb/Applications` → `uicache`，桌面启动，`/browse/` 48 张缩略图从 furaffinity.net 真实加载。装机脚本 `scripts/install-device.sh`。

**M0 的两个新结论（v3 补充）**
- **装机不需要 Mac 也不需要 TrollStore**：rootless 越狱机走 SSH + ldid + uicache 即可；`scp` 会卡死，改 `ssh 'cat > f'`（2.3MB / 2.7s）。
- **`AsyncImage` 在 FA 上必然全失败**：它用 `URLSession.shared`，无我们的 UA/cookie → Cloudflare 403。所有图片必须走 `FAHTTP`（`RemoteImage`）。这条对后面每个屏幕都成立。

**接下来**
9. ~~**M1 主体**~~ ✅ 已完成（2026-11-07，逐屏真机验收）：详情页 / 图片查看器 / 艺术家页 / 无限滚动 / 搜索。
   - 期间修掉三个真 bug：成人内容对访客返回 `Login Required` 空壳页（新增 `FAPageGuard`）；
     搜索页翻不动（目标页码在 Next 按钮的 `name/value` 上，不在 hidden input 里）；
     网格被 1:8 长条图撑爆（显示比例夹在 0.62~1.7）。
10. ~~**M2 Cloudflare 与会话**~~ ✅ 已完成（2026-11-08）：
    - 应用内 WKWebView 登录（Turnstile 由它承担，密码不经过 App）→ `a`/`b` 存 Keychain。
    - 常驻 WebView `FAWebHost`（全尺寸挂在视图层级最底层）负责续 Cloudflare 信任；导航全局串行化。
    - `FAFetch` 统一出口 + `ChallengeGate`（淘汰连接 → 暖机 → 再淘汰 → 恰好重试一次）。
    - 登录态自检：用 `/view/66962944/`（访客必得 Login Required）当探针，一次请求验证整条链路。
    - 真机结论：**进程重启与手机重启后登录态都还在**；`cf_clearance` 实测非必需（删掉后仍 200）。
    - 踩坑：`a`/`b` 必须成对更新（否则拼出「旧 a + 新 b」混合体，服务端判定访客）；ad-hoc 签名默认无
      entitlements → Keychain 静默失败（`-34018`），装机要 `ldid -S scripts/FAIOS.entitlements`。
11. **M3 账号功能**：收藏 / 关注 / 评论 / 通知 / Notes（收藏与关注的 URL 直接来自页面里的按钮 `href`，带 token，GET 即可）。

---

## 附录 A：实测证据（2026-11-07，本机 WSL）

```
GET https://www.furaffinity.net/                    200 / 123,063 B / 无 Cloudflare 挑战（guest）
GET https://www.furaffinity.net/login               200 / 含 4 处 "turnstile"
GET /search/?q=dragon                               200 / 171,395 B（guest 可搜）
GET /gallery/mimirelle/                             200 / 14 个 <figure id="sid-...">
GET /view/66962568/                                 200 / 80,908 B
    #submissionImg[data-fullview-src][data-preview-src][data-tags]
    data-tags="u_mimirelle c_ych_sale t_all s_unspecified_any furryart ych ..."
GET https://faexport.spangle.org.uk/                200 / v2025.12.1（第三方 API，仅作对照）
同一 IP 连续请求 → curl timeout（限速真实存在）
本机：WSL Ubuntu 24.04 ✓ / usbmuxd ✓ / Apple Mobile Device Service 运行中 ✓ / C 盘余 66.5 GB
      **Swift 6.4.1 ✓ / xtool ✓ / darwin SDK 3.2GB ✓**（v1 里记为 ✗，实测已装好）
      xcodebuild ✗（不需要）/ 设备 UDID 6cd303fb…（AirPlay 已断开，WSL 看不到 USB）
参考：github.com/Ceylo/FurAffinityApp  platforms: [.iOS("26.5")]  → 必须整体降级
```

## 附录 C：iOS 15 编译链路验证记录

```
~/T15  (从 ~/HelloXT 克隆，platforms 改 .iOS(.v15))
$ xtool dev build --ipa
Build complete! (48.96 secs) → xtool/HelloXT.ipa (115 KB)
Info.plist: MinimumOSVersion = 15.0        ✅

故意写 NavigationStack（iOS 16+）：
error: 'NavigationStack' is only available in iOS 16.0 or newer   ✅ 编译器强制拦截
```

## 附录 B：参考项目文档索引（值得再读）

| 路径 | 内容 |
|---|---|
| `Android/docs/cloudflare-and-login.md` | Cloudflare 全链路、挑战修复顺序、UA 绑定（已消化，见 §1.3） |
| `Android/docs/screens.md` | 屏幕级设计决策：图片查看器手势、深度链接评论、小说/音乐 |
| `Android/docs/images.md` | 图片管线；「Cloudflare judges a connection」 |
| `Android/docs/build-and-run.md` | 构建/运行（22KB，含 Android 槽位池，我们不需要） |
| `AGENTS.md` | 项目约定（18KB，给 AI 的工程规范，可借鉴书写风格） |
