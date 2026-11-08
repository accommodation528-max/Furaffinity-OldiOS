import Foundation
import Combine
import FAPages

extension Notification.Name {
    /// 登录状态变化（登录成功 / 退出登录），界面据此刷新
    static let faiosLoginDidChange = Notification.Name("faios.loginDidChange")
}

/// 页面抓取的**唯一入口**：查挑战 → 修 → 恰好重试一次。
///
/// 为什么不在 `FAHTTP` 里自己修：修复要动 WKWebView，而 WebView 只能在主线程碰；
/// `FAHTTP` 是 actor，不该知道 UI 的存在。
@MainActor
enum FAFetch {

    /// 拉一个页面，遇到 Cloudflare 挑战时先修再重试**一次**。
    ///
    /// 只重试一次是有原因的：Cloudflare 判定的是「连接」而不是「请求」。
    /// 盲重试等于用同一条被判过刑的连接再撞一次，浪费时间还加重限速。
    static func html(_ url: URL) async throws -> String {
        do {
            let text = try await FAHTTP.shared.fetchHTML(url)
            FADiag.record("GET \(url.path) → \(text.utf8.count)B title=\(FADiag.title(of: text)) loggedIn=\(FACookieStore.shared.isLoggedIn) loginRequired=\(FAPageGuard.isLoginRequired(text))")
            // Cloudflare 不一定回 403：有时它让 FA 直接把内容降级成访客视图
            // （HTTP 200 + 一句 Login Required 的空壳页）。我们明明带着 a/b 却被当访客，
            // 就是信任链断了 —— 修一次再取，且只重取一次。
            if FACookieStore.shared.isLoggedIn, FAPageGuard.isLoginRequired(text) {
                await ChallengeGate.shared.recover(interactive: false)
                let retried = try await FAHTTP.shared.fetchHTML(url)
                FADiag.record("RETRY \(url.path) → \(retried.utf8.count)B title=\(FADiag.title(of: retried)) loginRequired=\(FAPageGuard.isLoginRequired(retried))")
                return retried
            }
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch FAHTTP.FAHTTPError.challenge(let interactive) {
            FADiag.record("CHALLENGE \(url.path) interactive=\(interactive)")
            await ChallengeGate.shared.recover(interactive: interactive)
            return try await FAHTTP.shared.fetchHTML(url)
        }
    }

    /// 点一下 FA 页面上的按钮（收藏 / 关注 / 删除通知……）。
    ///
    /// 这类操作在 FA 上就是**一个带 token 的 GET 地址**：服务端处理完 302 回原页面，
    /// URLSession 自动跟随，所以我们拿到的已经是「动作生效后」的页面 —— 直接用它确认结果，
    /// 不用再额外请求一次。
    ///
    /// 遇到挑战时的顺序和 `html` 一样：先修再**恰好重试一次**。
    @discardableResult
    static func perform(_ url: URL) async throws -> String {
        do {
            let text = try await FAHTTP.shared.fetchHTML(url)
            FADiag.record("ACTION \(url.path) → \(text.utf8.count)B")
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch FAHTTP.FAHTTPError.challenge(let interactive) {
            FADiag.record("ACTION-CHALLENGE \(url.path) interactive=\(interactive)")
            await ChallengeGate.shared.recover(interactive: interactive)
            let text = try await FAHTTP.shared.fetchHTML(url)
            FADiag.record("ACTION-RETRY \(url.path) → \(text.utf8.count)B")
            return text
        }
    }
}

/// Cloudflare 挑战的修复流程。顺序不能改：
///
/// 1. **先淘汰已有连接** —— solve 要 1.5–25 秒，这期间其他请求还在污染连接池
/// 2. 让 WebView 重新过一遍（拿到新的 `cf_clearance`）
/// 3. **再淘汰一次** —— solve 期间新建的连接带的是旧 clearance
/// 4. 由调用方**恰好重试一次**
///
/// 还失败的，M2 先退化成「提示用户去『我的』里刷新」，而不是继续盲试。
@MainActor
final class ChallengeGate: ObservableObject {

    static let shared = ChallengeGate()

    /// 正在修（界面可以显示一条「正在通过 Cloudflare 验证」）
    @Published private(set) var isSolving = false

    /// 交互挑战需要用户亲手点：由 RootView 注入「弹登录/验证 sheet」的实现
    var interactivePresenter: (() async -> Void)?

    private init() {}

    func recover(interactive: Bool) async {
        guard !isSolving else { return }
        isSolving = true
        defer { isSolving = false }

        // 1. 丢掉现有的连接池（这一步在 WebView 之前，避免边修边污染）
        await FAHTTP.shared.resetConnections()

        // 2. 让 WebView 重新走一遍首页，Cloudflare 会在这时重发 cf_clearance
        await FAWebHost.shared.warmUpIfNeeded(force: true)

        // 3. 修的过程中可能又开了新连接，再淘汰一次
        await FAHTTP.shared.resetConnections()

        // 4. 交互挑战：必须让人看见并点一下
        if interactive, let presenter = interactivePresenter {
            await presenter()
        }
    }
}
