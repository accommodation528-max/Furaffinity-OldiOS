# FAIOS

FurAffinity 的第三方 iOS 客户端 —— **SwiftUI，最低 iOS 15，无需 Mac**。

> 非官方项目，与 Fur Affinity（Frost Dragon Art LLC）无隶属关系。
> 参考过的项目、第三方库与授权范围见 [NOTICE.md](NOTICE.md)，代码以 [MIT](LICENSE) 发布。

规划见 [docs/PLAN.md](docs/PLAN.md)。

---

## 目录结构

```
faios/
├── FAPages/                  # 纯解析层（独立 SwiftPM 包）
│   ├── Sources/FAPages/
│   │   ├── FAURLs.swift           # 所有 URL 集中点
│   │   ├── FAChallenge.swift      # UA 常量 / Cloudflare 挑战识别 / 节流参数
│   │   ├── FASubmission.swift     # 投稿模型（分级、类型）
│   │   ├── FASubmissionsPage.swift# <figure> 列表页解析 + 分页重建
│   │   └── FAPageError.swift
│   └── Tests/FAPagesTests/
│       ├── Fixtures/              # 真实页面快照（2026-11-07 抓取）
│       └── *.swift                # 22 个测试，Linux 上跑
├── FAIOS/                    # App（xtool 工程）
│   ├── Package.swift
│   ├── xtool.yml
│   └── Sources/FAIOS/
│       ├── FAIOSApp.swift
│       ├── RootView.swift         # 4 个 tab 的壳
│       ├── Core/Net/
│       │   ├── FAHTTP.swift       # 快路径：UA / cookie / 限流 / 挑战检测
│       │   ├── FACookieStore.swift
│       │   └── AsyncSemaphore.swift
│       └── Features/Browse/
│           └── BrowseScreen.swift # 端到端验证屏：真实抓取 → 解析 → 瀑布流
├── Vendor/SwiftSoup/         # HTML 解析库（vendored，避免构建期联网）
├── build/                    # 产出的 ipa
└── docs/PLAN.md
```

**为什么 FAPages 是独立包**：它零 UI、零网络依赖，所以能在 **Linux 上直接 `swift test`**，
不需要 Mac、模拟器或手机。改 UI 时解析逻辑不受牵连，FA 改版时测试先红。

---

## 跑测试

```bash
wsl  # 或直接在 WSL 里
cd /mnt/d/faios/FAPages
swift test
```

## 构建 ipa

```bash
bash scripts/build.sh        # 一条命令：编译 + 补 Info.plist + 拷到 build/
```

它比直接 `xtool dev build --ipa` 多两步：

1. `scripts/patch-ipa.py` 往 Info.plist 补 `UIBackgroundModes: [audio]` ——
   没有它，音乐一按 home 就停，锁屏也没有播放状态。
2. 同时塞进 `scripts/icons/Icon-*.png` 并登记 `CFBundleIconFiles`，
   以及**每次构建把 `CFBundleVersion` 涨一**（SpringBoard 的图标缓存按版本失效）。

产物 `build/FAIOS.ipa`，`MinimumOSVersion = 15.0`，未签名（设备有 TrollStore，不需要签名）。

图标本身由 `python scripts/make-icon.py` 生成（Pillow 画出来的爪印，改色改形状都改这一个文件）。

## 装到手机

测试机：**iPhone 7 Plus（iPhone9,2）/ iOS 15.8.3 / Dopamine rootless 越狱 / SSH 开着**。

**首选**（走 installd，App 有真实沙箱容器 + 桌面能显示自定义图标）：

```bash
bash scripts/install-trollstore.sh
```

它做的事：推 ipa 到 `/var/mobile/Media` → `trollstorehelper uninstall` → **`trollstorehelper install`** → `uicache -a`。

> 必须先卸载：`trollstorehelper install` 在「已安装」状态下会返回 **179**（force 参数返回 **166**），
> 都是装不进去的意思。卸载之后同一条命令返回 **0**，装到
> `/private/var/containers/Bundle/Application/<UUID>/FAIOS.app`。

备选（更快，但**没有数据容器**）：

```bash
bash scripts/install-device.sh
```

推 ipa → 手机端解包 → `ldid -S` 重签 → 放进 `/var/jb/Applications` → `uicache -a`。

> 这条路装出来的 App：`Documents` / `Library/Caches` / `Library/Preferences` 全部不可写，
> `UserDefaults` 写完全静默丢弃（见下面的坑），桌面上也只会是系统的网格占位图。
> 好处是不用卸载、不用点手机界面，迭代最快 —— 调试界面时够用。

两条路都会**清空 App 数据**（新容器），所以装完要重新登录一次。

---

## 真机调试

手机的屏幕镜像到本机后，可以「看 → 点 → 再看」闭环：

```
ios_use_screen        # 截图，返回路径 + 尺寸
ios_use_control tap   # x/y 归一化 0..1
```

截图里能直接看到失败原因（`RemoteImage` 会把错误文字画在格子里）——
真机上没有控制台，屏幕就是日志。

---

## 当前进度

| 里程碑 | 状态 |
|---|---|
| **M0 基础设施** | ✅ 编译链路、工程骨架、列表页解析器、`FAHTTP`、`RemoteImage` 图片管线、**真机跑通（真图出自 furaffinity.net）** |
| **M1 只读核心** | ✅ 首页 / 浏览 / 搜索 / 详情页 / 图片查看器 / 艺术家页 / 无限滚动，**全部真机验收**；37 个单测 |
| M2 Cloudflare 与会话 | ✅ 应用内 WKWebView 登录（密码不经过 App）、cookie 存 Keychain、**重启进程与重启手机后登录态仍在**；登录态自检与挑战修复链路已接 |
| **内容分级（SFW 开关）** | ✅ 「我的 → 内容分级」：全部 / 隐藏 Adult / 只看 General；列表过滤 + 缩略图 `M` / `18+` 角标 + 详情页遮罩。真机验收：首页 112 → 70 条 |
| M3 账号功能 | ✅ 收藏 / 关注 / 评论（只读）/ 通知 / 关注流 / 我的收藏 / **Notes（私信）**，全部真机验收；55 个单测 |
| **M4 阅读器** | ✅ Journal 阅读器（标题/作者/时间/分级/正文/评论）+ **小说阅读器**：BBCode 排版的正文、字号/行距可调、**退出重进回到上次位置**、PDF 走 PDFKit、docx/rtf 交给系统打开。真机验收（22,372 字德语故事） |
| **性能与图片缓存** | ✅ 两级缓存（内存 400 张 / 96MB + 磁盘 320MB）+ ImageIO 解码期降采样 + 静态资源独立车道。真机实测：重进页面 **省 53~59% 网络**，一屏 12 张出图时间从 4.2s 的量级降到 ~1s |
| **音乐播放器** | ✅ 详情页播放卡片（封面/进度/时间）+ 全局迷你播放条（切 tab 继续控制）+ 锁屏与控制中心（`MPRemoteCommandCenter`）+ 后台播放（补了 `UIBackgroundModes: [audio]`）。音频先下载再播 —— 直链要过 Cloudflare 与 cookie |
| **M5 打磨** | ✅ 诊断项收进「诊断」折叠区、版本号自动递增、App 图标（脚本生成）、**网络诊断与代理设置**、**外观开关（跟随系统/浅色/深色）**、**无障碍标签**（缩略图念「标题，作者 X，分级 Mature」；翻页四键、收藏、批量下载、标签 chip、关注/私信按钮都有 label）、**单张原图下载** |
| **屏蔽词** | ✅ 我的 → 屏蔽 → 屏蔽词（加词 / 左滑删除 / 清空）。命中**标题、作者名、任意标签**的投稿在列表里就地摘掉（不整页重拉，免得把人从详情页弹回列表）；详情页直接打开时盖一层说明并给一次放行。投稿页 `···` 菜单可一键「屏蔽这位作者」或挑一个标签屏蔽。真机：屏蔽 `dragon` 后首页 112 → 106 |
| **翻页与浏览增强** | ✅ 详情页底部翻页条（`«` 上一页 / `‹` 上个作品 / `›` 下个作品 / `»` 下一页）；中间是**本页位置**（`3 / 45`）与 `第 3 页 · 已加载 138`，分母是「这一页的条数」，不会随着翻页一直变大；某页整页重复时最多连跳 3 页；**关注名单**（我关注的 / 关注我的 + 名单内搜索）；**标签搜索**（点标签直接看该标签的列表）；**批量下载**（列表页右上角，存进「文件」App 可见的目录）。全部真机验收 |

### 已知的坑（都已写进代码注释）

- **`AsyncImage` 在 FA 上必定失败**：它走 `URLSession.shared`，带的是 CFNetwork 默认 UA 且没有 cookie，
  Cloudflare 直接 403。图片必须走我们自己的 `FAHTTP`（同 UA / 同 cookie），也就是 `RemoteImage`。
  实测：换成 `RemoteImage` 后 48 张缩略图全部加载成功。
- **UA 必须唯一**：`cf_clearance` 与 UA 逐字节绑定，改了 UA 等于重新过挑战
- **分页不是链接**：是 `method="GET"` 的表单，要从 hidden input 重建 query；
  **搜索页的页码不在 hidden input 里**，在 `Next` 按钮自己的 `name/value` 上（否则永远翻不动）
- **成人内容对未登录访客是 HTTP 200 的「Login Required」空壳页**，不是 403 —— 解析器要先过 `FAPageGuard`
- **浏览页默认全是图片**（48/48），首页才是混合的（图片 64 / 文章 24 / 音乐 24）
- **别用 `turnstile` 判断挑战**：正常登录页内嵌 4 处 Turnstile 控件，会误判
- **`swift-tools-version: 6.0` 默认 Swift 6 严格并发**，已在 `Package.swift` 显式退回 `.v5`
- **`scp` 在这台机器上会卡死**，用 `ssh 'cat > file'` 推文件（2.3MB / 2.7 秒）
- **`uiopen` 在 SSH 里是空操作**（对所有 App 都不启动，rc 却是 0），启动要用 ios-use 的 agent
- **极端宽高比会撑爆网格**：1:8 的长条漫画把整行拉到上千点高，显示比例要夹在 0.62~1.7
- **`UIScrollView` 的布局别挂在 `updateUIView`**：那时 bounds 常还是 0，图片会按原始像素铺开（真机表现：只看到图的一个角）
- **FA 的「小说」正文根本不在页面里**：`.text` 投稿只有一个 `Download` 链接，而且 `.txt` 文件内容是 **BBCode**（`[center]`/`[b]`/`[color=#c13d59]`/`[h1]`），
  有的还带 UTF-8 BOM 和 CRLF —— 直接当纯文本读会满屏方括号
- **这台机器上的 `UserDefaults` 是假的**：手动 `cp -R` 装的 .app 沙箱容器没初始化，`Documents` / `Library/Caches` / `Library/Preferences`
  全部不可写（`NSCocoaErrorDomain 513`），`UserDefaults` 写完全静默丢弃 → 所有设置一关 App 就回默认值。
  现在统一走 `FAStore`（自找可写目录写 JSON）。**换 TrollStore 安装后容器是真的**，
  `FAStore` 会优先进 `Documents/FAIOS/settings.json`（屏幕上的「设置存储位置」会显示真实路径）
- **`onChange(of:)` 等不到「内容视图出现」这件事**：视图是在数据就绪后才插进层级的，那时 `count` 早就不是 0 了，
  回调永远不来（阅读进度曾因此一条都存不下）——要挂在 `.onAppear`
- **`a` / `b` 是会话对，必须一起更新**：网页里 FA 会轮换 `b` 并清掉 `a`，无脑逐条吸收会存成「旧 a + 新 b」的混合体，
  服务端判定无效 → App 显示已登录、所有请求却按访客返回 Login Required（这个坑排查了很久，见 `FACookieStore.absorb`）
- **ad-hoc 签名默认没有 entitlements**：`ldid -e <binary>` 输出为空 → Keychain 写入静默失败（`-34018`），
  登录态一重装就丢。安装脚本必须 `ldid -S scripts/FAIOS.entitlements`
- **手动拷贝安装的 App 写不进自己的容器**：`Documents/diag.log` 报 `NSCocoaErrorDomain 513`，
  真机没有控制台时只能把诊断信息画到屏幕上
- **Cloudflare 挑战不一定发生**：删掉 `cf_clearance` 后请求依然 200（带 `a`/`b` 就够），
  所以挑战修复链路目前只是保险，未被真实触发过
- **分级参数只有 `/browse` 与 `/search` 认**（`rating_general/mature/adult` = 1/0），首页与艺术家画廊不吃这套，
  所以内容过滤是「服务端参数 + 客户端按解析出的 `rating` 再筛一遍」两层，缺一不可
- **收藏 / 关注就是一个带 token 的 GET**（`href` 里的 `key=` 就是 token），不用逆向表单；
  但**不能拿动作的响应当结果**：`/watch/{user}/?key=` 跳回来的页面结构跟用户页不一样
- **图片别跟页面挤同一条限流车道**：页面 3 并发 / 350ms 间隔是有理由的（每页 100KB+ 后端渲染），
  但缩略图是 CDN 上的静态文件，按 350ms 串着取的话**一屏 12 张要 4.2 秒**，真机冷启动整屏灰格子。
  `FAHTTP` 现在按 host 分两条道：`t.` / `a.` / `d.` 子域 6 并发 / 80ms，页面不变
- **降采样要在解码阶段做**：`UIImage(data:)` 按原始像素解码，2474×1489 一张就 14.7MB；
  用 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize` 直接解成 420px，
  同样的图只占 ~0.4MB（**36 倍**）。缩略图档位实测：`@200/@300/@400/@600` 可用，`@800` 以上 301
- **手动拷贝安装的 App 连自己的 `Caches` 都写不了**（不只是 Documents）：图片磁盘缓存因此要做
  「逐级试探可写目录」——实测最终落在 `/tmp/faios-images`（屏幕上那份统计会显示真实路径）
- **失败反馈不能拿「动作的响应」当结果**：`/watch/{user}/?key=` 跳回来的页面结构跟用户页不一样
  （解析出的用户名、头像、统计全对不上）。正确做法是乐观翻转 + 重新抓原页面确认
- **xtool 不生成 `UIBackgroundModes`，也不生成图标**：`xtool.yml` 只认 `version` 与 `bundleID`。
  后台音频与 App 图标都得在 ipa 产物上打补丁（`scripts/patch-ipa.py`），
  而且 `install-device.sh` 必须默认装 `build/` 里那份打过补丁的 ipa，否则补丁白打
- **SpringBoard 的图标缓存按 `CFBundleVersion` 失效**：版本号不变时换了图标也只会继续显示旧图/占位图，
  所以每次构建都自动涨一个 build 号（「我的 → 关于 → 版本」能直接看到）
- **手动 `cp -R` 装进 `/var/jb/Applications` 的 App 在这个越狱环境里拿不到自定义图标**：
  Spotlight 与桌面仍是系统的网格占位图（同一路径下所有手装 App 都一样）。
  改用 `scripts/install-trollstore.sh`（走 installd）后图标立刻正常，**并且**顺带解决了容器不可写的问题
- **`trollstorehelper install` 的返回码会骗人**：已安装时返回 179、带 force 参数返回 166，
  只有「先 `uninstall` 再 `install`」才返回 0；不 `uninstall` 的话新包根本进不去
- **装了 TrollStore 版之后 `Documents/diag.log` 又能写了**：沙箱容器是真的，
  于是「真机没有控制台、只能把日志画到屏幕上」这条约束可以退休（`FADiag` 仍然保留，两条通道都在）
- **音乐投稿的 `<audio src>` 不能直接丢给 `AVAudioPlayer`**：那个直链同样要过 Cloudflare 与 cookie，
  `AVPlayer(url:)` 不带我们的请求头，结果是静默失败。必须先 `FAFetch.data` 下载到本地再从文件播
- **需要登录的页面只能从手机上取**：开发机（WSL）没有 cookie，
  用「我的 → 导出页面快照（调试）」把页面写到 `/var/tmp`，再 `ssh cat` 取回当 fixture
- **`RelativeDateTimeFormatter` 跟系统语言走**：设备是英文系统，界面是中文，相对时间会变成 "2 yr. ago"，
  统一走 `FAFormat.relative` 强制 zh_Hans（同理 `Section` 标题会被自动大写，要 `.textCase(nil)`）
- **发私信不能走 HTTP**：`/newpm/{user}/` 的表单里嵌着 Cloudflare Turnstile，直接 `URLSession` POST `/msg/send/`
  只会拿到 `CAPTCHA verification failed`。发信必须在真实 `WKWebView` 里做（`ComposeNoteWebView`）：
  填表 → 人点一下「请验证您是真人」→ 我们轮询隐藏 input `cf-turnstile-response` → `requestSubmit()`
- **点击页面上的 `Send Note` 按钮无效**，但 JS `requestSubmit()` 有效（同一表单）——只能程序化提交
- **发信结果页有三种形态，只认一种就会假成功**：
  ① `section.notice-message`（CAPTCHA 失败等）② `System Error`（只有 `<h2>` + `section-body`，例如
  「You cannot send notes to yourself」）③ **写信页原样重渲染**（FA 静默拒绝，一句提示都没有）。
  判据是「离开 `/newpm/` 且看到私信列表」，不是「没有错误提示」
- **`didFinish` 不是「DOM 就绪」**：`didCommit` 更早，两者都要触发填表，而且要读回字段确认填上了再提交
  （实测 `didCommit` 时表单还没长出来，主题和正文是空的 → 提交必然失败）
- **FA 拒绝给自己发私信**（`You cannot send notes to yourself`）。这反而是最好的验证：能走到这句错误，
  就说明 cookie、Turnstile、表单提交、结果解析**全都对了**，只差一个真实收信人
- **「所有请求超时」先查 DNS，别怀疑代码**：这台机器所在网络把 `www.furaffinity.net` 解析成
  `173.252.248.244`（Facebook 的地址），而 `example.com` 正常 1.2 秒 200 —— 症状是首页永远转圈、
  日志里只有 `HEALTH start` 没有任何 `GET` 完成行。诊断命令在 App 里：「我的 → 网络」的「网络自检」
  （会打印四路对照 + DNS 解析结果到屏幕和 `diag.log`）
- **iOS 的 `NSURLSession` 不认 `connectionProxyDictionary` 里的 SOCKS 键**：填 `socks://127.0.0.1:1080`
  后所有请求立刻报 `The Internet connection appears to be offline.`。只支持 HTTP/HTTPS 代理；
  SOCKS 只能靠系统级代理 App（VPN 模式）
- **`connectionProxyDictionary` 只作用于我们的 `URLSession`**：`WKWebView`（登录页、发私信页）走系统网络栈，
  不读这个设置 —— 这两个场景必须让代理 App 在系统层生效
- **FA 的详情页没有任何 prev/next 链接**（全量扫过 `detail-logged-in.html` 的 `<a>`）：所谓「翻下一张」
  只能靠我们自己的列表上下文实现 —— 列表把 `BrowseViewModel` 连同 `pageStarts` 一起传进详情页，
  才知道「这是第几张、下一页从哪开始」
- **横向 `ScrollView` 里的 chip 点不动**：标签条当初放在 `ScrollView(.horizontal)` 里，真机点上去毫无
  反应（手指真实滑动才生效，那层滚动手势把 tap 吃掉了）。改成自动换行的流式布局 + 隐藏
  `NavigationLink(isActive:)` 才可点
- **批量下载只能下 @600**：列表页的 `figure` 里只有缩略图地址（`t.furaffinity.net/…@200-…`），原图地址
  只存在于详情页的 `data-fullview-src`。要原图得进详情页单张下载
- **下载目录要在「文件」App 里可见**，得往 Info.plist 补 `UIFileSharingEnabled` 与
  `LSSupportsOpeningDocumentsInPlace`（`scripts/patch-ipa.py` 已加）——否则文件躺在容器里，用户看不到
- **首页没有分页**：`https://www.furaffinity.net/?page=2` 返回的 122,871 字节与首页逐字节同构
  （首条都是 `sid-66972830`），所以首页的 `»` 恒为灰是正确行为，不是 bug
- **某一页可能整页都是重复条目**：FA 在两次请求之间插新投稿，分页结果整体后移，
  去重后这一页可能一条不剩。以前 `pageStart(after:)` 直接返回 `nil`，表现是「点 `»` 没反应」，
  像页数被卡住；现在最多连跳 3 页去找新内容
- **`TextField` 里别放中文括号当占位符**：`HTTP 代理 host:port（留空=直连）` 在窄屏会被截成
  `…（留空=直…`，占位符要短
- **`data-tags` 是一整串带前缀的 token**：`u_spyro1mario c_all t_all s_dragon dragon …`，
  前缀 `u_/c_/t_/s_/a_` 是 FA 自己的分类标记。用户想屏蔽的是 `dragon` 而不是 `s_dragon`，
  所以每个 token 要同时给出「原样」和「去前缀」两种形式
- **过滤后不要整页重拉**：`reload()` 会把 `submissions` 清空再填，`NavigationLink` 的数据源
  瞬间变空 → 正停在详情页的用户被直接弹回列表
- **就地摘条目也会弹**：列表行是 `NavigationLink` 的数据源，只要那一行从集合里消失，**
  正停在它详情页的人立刻被弹回列表**（实测：详情页按「屏蔽这位作者」，自己被弹回首页）。
  正确做法是「记脏标记 + 等用户自己回到列表（`onAppear`）再摘」；详情页的遮罩判定也
  要在**进入时算一次冻住**，否则按下屏蔽的瞬间当前这页被自己的遮罩盖住
- **屏蔽词变更后要重拉，不要只做就地摘行**：摘行只能让命中的消失，**删词之后回不来**
  （行已经从 `submissions` 里删掉了）。现在收到变更只置脏标记，列表 `onAppear` 时重拉
- **TrollStore 卸载会连数据容器一起删**：所以 `scripts/install-trollstore.sh` 现在先备份
  `Documents/FAIOS` 再装、装完恢复 —— 否则每次升级都丢设置、丢下载、丢阅读进度
- **iOS 15 的 `ToolbarContentBuilder` 不支持 `if`**：条件插 `ToolbarItem` 报
  `'buildIf' is only available in iOS 16.0 or newer`，改成「一直挂着 + 空态时 opacity 0 且 disabled」

---

## 参考与授权

- 参考项目：**[Ceylo/FurAffinityApp](https://github.com/Ceylo/FurAffinityApp)**（无 LICENSE）
  —— 只参考了架构分层、FA 页面选择器的事实性信息、以及 Cloudflare 挑战的处理经验，
  **没有复制其代码，也没有把它的文件放进本仓库**
- 本仓库代码：[MIT](LICENSE)。`FAPages/Tests/FAPagesTests/Fixtures/` 里的 HTML 是
  furaffinity.net 的页面快照，版权归 FA / 对应作者，仅作解析器回归测试
- 非官方项目，与 Fur Affinity 无隶属关系；详细声明见 [NOTICE.md](NOTICE.md)

## 测试

```bash
cd FAPages && swift test      # 74 个单测，Linux 上直接跑（不需要 macOS / 模拟器）
```

解析层的每个选择器都由 `Fixtures/` 里的真实页面快照兜着 —— FA 改版时先跑测试，
失败的用例会直接指出是「列表页」「详情页」「用户页」「私信」「小说」哪一块变了。
