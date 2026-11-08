import Foundation
import Combine
import FAPages

/// 「我是谁」：登录后抓到自己的用户名（slug），用来拼「我的收藏」这类只跟自己有关的地址。
///
/// 为什么要单独存：FA 的账号菜单里 `<a id="my-username">` 的 href 是 `#`，
/// 用户名只出现在显示名上，而显示名可能和用户名不同（大小写、空格、改名都不一致）。
/// 唯一稳妥的取法是登录后的 `/controls/` 页面 —— 那里菜单里有一项指向 `/user/{slug}/`。
@MainActor
final class FAAccountStore: ObservableObject {

    static let shared = FAAccountStore()

    /// 自己的用户名（小写，FA 的 url slug）
    @Published private(set) var slug: String?

    private var isLoading = false
    private var loadedOnce = false

    private init() {
        slug = UserDefaults.standard.string(forKey: Self.defaultsKey)
    }

    private static let defaultsKey = "fa.account.slug"

    /// 只在登录后调用；已拿到且不强制刷新时直接返回
    func refreshIfNeeded(force: Bool = false) async {
        guard FACookieStore.shared.isLoggedIn else {
            clear()
            return
        }
        if !force && loadedOnce { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let html = try await FAFetch.html(FAURLs.controls)
            if let identity = try? FAAccount.parse(html, from: FAURLs.controls) {
                setSlug(identity.slug)
                loadedOnce = true
            }
        } catch {
            FADiag.record("identity 失败：\(FAErrorMessage.describe(error))")
        }
    }

    func setSlug(_ value: String) {
        guard !value.isEmpty else { return }
        slug = value
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
    }

    func clear() {
        slug = nil
        loadedOnce = false
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// 我的收藏页地址；还不知道自己是谁的时候返回 nil（界面据此藏掉入口）
    var favoritesURL: URL? {
        guard let slug else { return nil }
        return FAURLs.favorites(slug)
    }
}
