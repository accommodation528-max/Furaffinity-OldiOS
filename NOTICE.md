# NOTICE / 参考与声明

## 本项目与 Fur Affinity 的关系

FAIOS 是**非官方**第三方客户端，与 Fur Affinity（Frost Dragon Art LLC）无任何隶属、
授权或背书关系。「Fur Affinity」名称与相关标识归其所有者所有，本项目仅在描述
「所访问的服务」时使用。

本项目不分发 FA 的任何内容（投稿、头像、小说文本等），只在运行时按用户身份请求页面；
`FAPages/Tests/FAPagesTests/Fixtures/` 下的 HTML 是页面快照，仅供解析器回归测试。

## 参考过的项目

- **[Ceylo/FurAffinityApp](https://github.com/Ceylo/FurAffinityApp)** —— 同类的非官方
  FA 客户端（iOS / Android）。本项目在**架构分层思路**（解析层与 UI 层分离）、
  FA 页面选择器的事实性信息、以及 Cloudflare 挑战处理的经验结论上参考了它，
  其中的 `Android/docs/cloudflare-and-login.md` 与 `screens.md` 是很好的实测记录。

  **该仓库没有 LICENSE 文件，因此默认「保留所有权利」。本项目没有复制它的任何代码、
  也没有把它的文件放进本仓库**（早期版本曾把两份 fixture 取自该仓库，已替换为本项目
  自己编写的等价样本）。选择器、URL 形态、站点行为属于事实性信息，不受著作权保护；
  但如果你是该项目的作者并认为这里有越界，请提 issue，会立即调整。

  本项目的差异在于**面向 iOS 15**（参考项目要求 iOS 26.5），因此整个 UI 层、网络层、
  缓存与阅读器都是重写的；页面解析层也是按本站 2026-11 的实际 HTML 重新验证的。

- **[FAExport](https://faexport.spangle.org.uk/)** —— 第三方只读 API。本项目没有接入它
  （会把用户的 FA cookie 交给第三方服务器），但读过它的端点与字段设计。

## 第三方库

- **[SwiftSoup](https://github.com/scinfu/SwiftSoup)**（MIT）—— 以源码方式放在 `Vendor/`，
  避免构建期联网。其 LICENSE 一并保留在 `Vendor/SwiftSoup/LICENSE`。

## 工具链

- **[xtool](https://github.com/xtool-org/xtool)** —— 在 Linux / Windows(WSL) 上完成
  xcodebuild 的职责（编译、打包 ipa）。没有它，这个项目在无 Mac 环境下无法构建。
- 构建与装机流程见 `README.md` 的「构建」「装机」两节。

## 致谢

- 给 FA 上愿意让第三方客户端存在的画师与作者；
- 给 Ceylo 把 Cloudflare 那一套（UA 绑定、常驻 WebView、淘汰连接再重试）写成文档的人 ——
  没有那份记录，M2 大概要多花一周。
