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
| **M0 基础设施** | ✅ 编译链路、工程骨架、列表页解析器（22 测试）、`FAHTTP`、`RemoteImage` 图片管线、**真机跑通（真图出自 furaffinity.net）** |
| M1 只读核心 | ⬜ 详情页 / 图片查看器 / 艺术家页 / 分页加载 |
| M2 Cloudflare 与会话 | ⬜ 常驻 WKWebView + 挑战修复 + 登录 |
| M3 账号功能 | ⬜ 关注流 / 收藏 / 关注 / 通知 / Notes |
| M4 阅读器 | ⬜ 小说 / Journal / 进度记忆 |
| M5 打磨 | ⬜ 主题 / 无障碍 / 图标 |

### 已知的坑（都已写进代码注释）

- **`AsyncImage` 在 FA 上必定失败**：它走 `URLSession.shared`，带的是 CFNetwork 默认 UA 且没有 cookie，
  Cloudflare 直接 403。图片必须走我们自己的 `FAHTTP`（同 UA / 同 cookie），也就是 `RemoteImage`。
  实测：换成 `RemoteImage` 后 48 张缩略图全部加载成功。
- **UA 必须唯一**：`cf_clearance` 与 UA 逐字节绑定，改了 UA 等于重新过挑战
- **分页不是链接**：是 `method="GET"` 的表单，要从 hidden input 重建 query
- **浏览页默认全是图片**（48/48），首页才是混合的（图片 64 / 文章 24 / 音乐 24）
- **别用 `turnstile` 判断挑战**：正常登录页内嵌 4 处 Turnstile 控件，会误判
- **`swift-tools-version: 6.0` 默认 Swift 6 严格并发**，已在 `Package.swift` 显式退回 `.v5`
- **`scp` 在这台机器上会卡死**，用 `ssh 'cat > file'` 推文件（2.3MB / 2.7 秒）
