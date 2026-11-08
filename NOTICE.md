# NOTICE / 参考与声明

## 本项目与 Fur Affinity 的关系

FAIOS 是**非官方**第三方客户端，与 Fur Affinity（Frost Dragon Art LLC）无任何隶属、
授权或背书关系。「Fur Affinity」名称与相关标识归其所有者所有，本项目仅在描述
「所访问的服务」时使用。

本项目不分发 FA 的任何内容（投稿、头像、小说文本等），只在运行时按用户身份请求页面；
`FAPages/Tests/FAPagesTests/Fixtures/` 下的 HTML 是页面快照，仅供解析器回归测试。

## 参考过的项目

### Ceylo/FurAffinityApp

<https://github.com/Ceylo/FurAffinityApp> —— 同类的非官方 FA 客户端（iOS / Android）。
本项目在**架构分层思路**（解析层与 UI 层分离）、FA 页面选择器的事实性信息、
以及 Cloudflare 挑战处理的经验结论上参考了它。

**该仓库没有 LICENSE 文件，因此默认「保留所有权利」。本项目没有复制它的任何代码。**
唯一一次文件级复制是早期把两份测试 fixture（`notes-list` / `notes-unread`）取自该仓库，
现已替换为本项目针对同样结构自己编写的样本（解析器与测试未改动，仍然全绿）。

具体读过的文件（逐项列清，方便核对）：

| 来源文件 | 用到了什么 |
|---|---|
| `Android/docs/cloudflare-and-login.md` | UA 后缀标识应用、**常驻一个全尺寸但被遮住的 WebView**（1×1 时 Turnstile 容器会塌成 0×69）、挑战修复的五步顺序（淘汰连接 → 等待 → 再淘汰 → 只重试一次）、WebView 导航必须全局串行 |
| `Android/docs/screens.md` | 屏幕清单与各屏做法：图片查看器的手势协商、小说阅读器按扩展名分流且不能一次性测量整本、音乐先下载再交给播放器 |
| `FAKit/Sources/FAPages/FAURLs.swift` 及同目录解析文件 | FA 的 URL 形态与选择器事实（`img#submissionImg` 的 `data-fullview-src`、`+Fav` 按钮的 `href` 本身就是带 token 的收藏地址、用户页的自定义标签、私信／通知的容器结构） |
| `FAKit` 里的 `OnlineFASession.sendNote(apiKey:toUsername:subject:message:)` | POST `/msg/send/` 的四个表单字段名（`key` / `to` / `subject` / `message`） |

哪些不算「抄」：选择器、URL、表单字段、页面结构都是**关于 FA 站点的事实**，不受著作权保护；
「常驻 WebView」「淘汰连接后只重试一次」属于**思路**，法律保护的是表达而非想法，我们的实现是
按 iOS 15 重写的另一套代码。可以核对的地方是：本仓库每个选择器都由**自己的 fixture** 验证
（见 `FAPages/Tests/`），测试红了就说明页面结构变了，与参考项目无关。

**命名上的说明**：模块名 `FAPages`、文件名 `FAURLs.swift` 沿用了对方的分层命名，看起来像同一个
项目。这是刻意保留的 —— 改个名字反而像在遮掩，而且它准确描述了职责（「FA 的页面解析」）。
如果你是该项目的作者并认为这里有越界，请提 issue，会立即调整。

本项目的差异在于**面向 iOS 15**（参考项目要求 iOS 26.5），因此整个 UI 层、网络层、
缓存与阅读器都是重写的；页面解析层也是按本站 2026-11 的实际 HTML 重新验证的。

### FAExport

<https://faexport.spangle.org.uk/> —— 第三方只读 API。本项目没有接入它
（会把用户的 FA cookie 交给第三方服务器），但读过它的端点与字段设计。

## 第三方库

- **[SwiftSoup](https://github.com/scinfu/SwiftSoup)**（MIT）—— 以源码方式放在 `Vendor/`，
  避免构建期联网。其 LICENSE 一并保留在 `Vendor/SwiftSoup/LICENSE`。

## 测试用页面快照

`FAPages/Tests/FAPagesTests/Fixtures/` 下的 `.html` 是**解析层回归测试用的页面快照**：
它们是从 furaffinity.net 抓下来（或按真实结构重写）的页面副本，权利归
Frost Dragon Art LLC 与各投稿作者所有，**不在本仓库 MIT 许可范围内**。

它们存在的唯一目的是让「站点改版导致解析失效」这件事在 CI 里可见（`swift test`），
不是作为内容再分发。若你是权利人希望移除其中某一份，开一个 issue，会直接删掉对应文件
（相关测试随之改用内联片段）。

## 工具链

- **[xtool](https://github.com/xtool-org/xtool)** —— 在 Linux / Windows(WSL) 上完成
  xcodebuild 的职责（编译、打包 ipa）。没有它，这个项目在无 Mac 环境下无法构建。
- 构建与装机流程见 `README.md` 的「构建」「装机」两节。

## 致谢

- 给 FA 上愿意让第三方客户端存在的画师与作者；
- 给 Ceylo 把 Cloudflare 那一套（UA 绑定、常驻 WebView、淘汰连接再重试）写成文档的人 ——
  没有那份记录，M2 大概要多花一周。
