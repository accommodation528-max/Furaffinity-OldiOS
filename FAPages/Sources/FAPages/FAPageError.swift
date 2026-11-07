import Foundation

/// 解析失败的原因。刻意做成 describeable，日志里直接能看出是哪一段坏了。
public enum FAPageError: Error, CustomStringConvertible {
    /// HTML 本身无法被解析
    case malformedHTML(String)
    /// 期望存在的元素没找到（页面结构变了 / 被 Cloudflare 拦了 / 未登录）
    case missingElement(String)
    /// 找到了元素但字段内容无法识别
    case unexpectedValue(_ field: String, raw: String)
    /// FA 对这个页面要求登录（成人/敏感内容对未登录访客直接返回 Login Required 页）
    case loginRequired

    public var description: String {
        switch self {
        case .malformedHTML(let m):     return "HTML 解析失败: \(m)"
        case .missingElement(let m):    return "缺少元素: \(m)"
        case .unexpectedValue(let f, let r): return "字段 \(f) 的值无法识别: \(r)"
        case .loginRequired:            return "需要登录才能查看"
        }
    }
}

/// 页面级的前置判断。
///
/// FA 对未登录访客的「成人内容」详情页会直接返回一张
/// `<title>Login Required -- Fur Affinity [dot] net</title>` 的普通页面（状态码仍是 200），
/// 结构里什么都没有 —— 所以必须在解析前先认出来，否则会报一堆莫名其妙的「缺少元素」。
public enum FAPageGuard {

    public static func isLoginRequired(_ html: String) -> Bool {
        // 保守：同时认 title 与页面里出现的那句提示语，避免只改了一处
        if html.contains("<title>Login Required") { return true }
        if html.contains("Login Required -- Fur Affinity") { return true }
        if html.contains("You must be logged in to view this page") { return true }
        return false
    }

    /// 解析前调用；是登录页就抛 `.loginRequired`
    public static func check(_ html: String) throws {
        if isLoginRequired(html) { throw FAPageError.loginRequired }
    }
}
