import Foundation
import FAPages

/// 登录态自检：用一个**确定需要登录**的投稿验证整条会话链路。
///
/// 为什么需要它：cookie 存进 Keychain 不等于服务器认。
/// `/view/66962944/` 这个投稿实测对访客返回 22.7KB 的 `Login Required` 空壳页（HTTP 200），
/// 登录后才会给出真正的页面 —— 拿它当探针，一次请求就能判断
/// 「cookie 带上了 + Cloudflare 放行了 + 解析器认得」三者是否同时成立。
///
/// 这也是给用户看的：出问题时点一下，屏幕上直接说清楚卡在哪一环。
@MainActor
enum FAHealthCheck {

    /// 实测对访客一律返回 Login Required 的投稿（成人内容）
    static let loginOnlySubmissionID = 66962944

    static func run(forceChallenge: Bool = false) async -> String {
        guard FACookieStore.shared.isLoggedIn else {
            return """
            未登录：还没有 a/b cookie
            存储位置：\(FACookieStore.shared.storageDescription())
            """
        }

        // 人为制造一次挑战：只删 cf_clearance，a/b 保留 → 请求大概率被 Cloudflare 拦一次，
        // 正好把 FAFetch 的「挑战修复 + 恰好重试一次」跑通。这是不弄丢登录态的唯一测法。
        var challengeNote = ""
        if forceChallenge {
            let removed = FACookieStore.shared.remove("cf_clearance")
            await FAHTTP.shared.resetConnections()
            challengeNote = removed
                ? "（已先删掉 cf_clearance，制造一次挑战）\n"
                : "（本来就没有 cf_clearance）\n"
        }

        let url = FAURLs.submission(loginOnlySubmissionID)
        let diagStatus = FADiag.recordSync("HEALTH start cookies=\(FACookieStore.shared.describeCookies()) storage=\(FACookieStore.shared.storageDescription())")
        do {
            let html = try await FAFetch.html(url)
            let detail = try FASubmissionDetail.parse(html, from: url)
            return """
            \(challengeNote)登录态有效 ✅
            能读到需登录的投稿：\(detail.title)
            分级：\(detail.rating) · 类型：\(detail.kind)
            说明 cookie 已带上，且 Cloudflare 放行
            cookie：\(FACookieStore.shared.cookieCount) 条 · 存在 \(FACookieStore.shared.storageDescription())
            """
        } catch FAPageError.loginRequired {
            // 「本地有 a/b 但服务器说你是访客」只有三种可能：①a/b 不成对（被拆开更新过）
            // ②服务端会话已过期 ③缺 cf_clearance 且 FA 把请求降级成访客。
            // 这里把现场全打出来，配合 web= 那行就知道该重登还是该续信任。
            let hasA = FACookieStore.shared.value(for: "a") != nil
            let hasB = FACookieStore.shared.value(for: "b") != nil
            let pairNote = hasA == hasB ? (hasA ? "a/b 都在" : "a/b 都缺") : "a/b 缺失一半 ⚠️"
            return """
            \(challengeNote)会话无效 ❌
            服务器仍把这次请求当成访客（返回 Login Required 页）。
            \(pairNote) · 存储 \(FACookieStore.shared.storageDescription())
            cookie：\(FACookieStore.shared.describeCookies())
            a=\(FACookieStore.shared.value(for: "a") ?? "-")
            b=\(FACookieStore.shared.value(for: "b") ?? "-")
            web=\(FAWebHost.shared.lastSyncedSummary)
            diag：\(diagStatus)
            写盘：\(FADiag.probeWritablePaths())
            """
        } catch {
            return "自检失败：\(FAErrorMessage.describe(error))\ndiag：\(diagStatus)"
        }
    }
}
