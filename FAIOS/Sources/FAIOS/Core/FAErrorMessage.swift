import Foundation
import FAPages

/// 把错误翻译成给人看的一句话。
///
/// 真机没有控制台，屏幕上这句话就是我们的日志 —— 所以既要简短，又要能定位问题。
enum FAErrorMessage {

    static func describe(_ error: Error) -> String {
        if let pageError = error as? FAPageError {
            switch pageError {
            case .loginRequired:
                return "这个投稿需要登录才能看（成人内容对未登录访客不可见）"
            case .missingElement(let name):
                return "页面结构变了：找不到 \(name)"
            case .malformedHTML(let detail):
                return "页面解析失败：\(detail)"
            case .unexpectedValue(let field, let raw):
                return "字段 \(field) 认不出来：\(raw)"
            }
        }
        return String(describing: error)
    }
}
