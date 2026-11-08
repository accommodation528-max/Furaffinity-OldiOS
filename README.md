# FAIOS

FurAffinity 的第三方 iOS 客户端 —— **SwiftUI，最低 iOS 15，无需 Mac**。

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
cd /mnt/d/faios/FAIOS
xtool dev build --ipa        # → FAIOS/xtool/FAIOS.ipa
```

产物 `MinimumOSVersion = 15.0`，未签名（设备有 TrollStore，不需要签名）。

## 装到手机

测试机：**iPhone 7 Plus（iPhone9,2）/ iOS 15.8.3 / Dopamine rootless 越狱 / SSH 开着**。

一条命令（走局域网 SSH，不需要 Mac / Apple ID / 数据线）：

```bash
bash scripts/install-device.sh
```

它做的事：推 ipa → 手机端解包 → `ldid -S` 重签 → 放进 `/var/jb/Applications` → `uicache -a` 注册。

> 为什么不用 TrollStore 装？rootless 越狱机直接往 `/var/jb/Applications` 放 .app 更快，
> 而且不用点手机上的任何界面。**未越狱**设备才需要 TrollStore / AltStore。

手动机装（TrollStore 路线）：把 `build/FAIOS.ipa` 传到手机 → 点它 → 分享 → TrollStore。

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
| M4 阅读器 | 🟡 Journal 阅读器 ✅（标题/作者/时间/分级/正文/评论）；小说阅读器 ⬜；进度记忆 ⬜ |
| **性能与图片缓存** | ✅ 两级缓存（内存 400 张 / 96MB + 磁盘 320MB）+ ImageIO 解码期降采样 + 静态资源独立车道。真机实测：重进页面 **省 53~59% 网络**，一屏 12 张出图时间从 4.2s 的量级降到 ~1s |
| M5 打磨 | ⬜ 主题 / 无障碍 / 图标 |

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
  （解析出的用户名、头像、统计全对不上）。正确做法是乐观翻转 + 重新抓原页面确认
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
