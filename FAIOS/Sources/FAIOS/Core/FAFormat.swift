import Foundation

/// 相对时间（「2 年前」「3 小时前」）。
///
/// 为什么要自己写一层：`RelativeDateTimeFormatter()` 默认跟随系统区域设置，
/// 而这台设备系统语言是英文，于是界面里全是 "2 yr. ago" —— App 的文案是中文的，
/// 时间也必须跟着中文，否则半中半英很难看。
enum FAFormat {

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "刚刚" }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        let text = formatter.localizedString(for: date, relativeTo: now)
        // 中文下偶尔会带「前」字重复；统一收一下空白
        return text.replacingOccurrences(of: " ", with: "")
    }

    /// 「2026-11-08 09:08」
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 「2019」
    static func year(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    /// 「1.2 万」这种量级？暂时不做 —— FA 的计数本来就不大，直接显示数字更准
    static func count(_ value: Int) -> String {
        value > 9999 ? String(format: "%.1f万", Double(value) / 10000) : String(value)
    }
}
