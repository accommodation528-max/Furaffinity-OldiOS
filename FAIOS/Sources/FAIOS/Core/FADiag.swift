import Foundation

/// 真机没有控制台，出问题只能靠「把现场写进文件，再用 SSH 拿出来」。
///
/// 位置：`Documents/diag.log`（每次启动不清空，方便看历史；读法见 README）
enum FADiag {

    private static let queue = DispatchQueue(label: "app.faios.diag")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var logURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("diag.log")
    }

    static func record(_ message: String) {
        queue.async {
            let line = "[\(stamp.string(from: Date()))] \(message)\n"
            let url = logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// 同步写一次并把结果返回（真机上看不到控制台，这个字符串会显示在屏幕上，
    /// 用来判断「到底是路径不对、还是沙箱不让写」）
    static func recordSync(_ message: String) -> String {
        let url = logURL
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url)
            }
            return "ok \(url.path)"
        } catch {
            return "FAIL \(url.path) :: \(error)"
        }
    }

    /// 从 HTML 里抠出 title，日志里一眼能看出服务器给的是哪个页面
    static func title(of html: String) -> String {
        guard let start = html.range(of: "<title>"),
              let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex)
        else { return "(no title)" }
        return String(html[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 探针：在几个候选目录里各写一个文件，返回能写的那几个。
    /// 背景：手动拷贝安装的 App 写 `Documents` 会报 `NSCocoaErrorDomain 513`（沙箱没给容器），
    /// 需要先找出到底哪里可写，才知道日志该落在哪。
    static func probeWritablePaths() -> String {
        var candidates: [(String, URL)] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(("Documents", docs))
        }
        candidates.append(("tmp(NSTemporaryDirectory)", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)))
        candidates.append(("home", URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)))
        candidates.append(("Library/Caches", FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/var/mobile/Library/Caches", isDirectory: true)))
        candidates.append(("var/tmp", URL(fileURLWithPath: "/var/tmp", isDirectory: true)))
        candidates.append(("var/mobile", URL(fileURLWithPath: "/var/mobile", isDirectory: true)))
        candidates.append(("prefs", URL(fileURLWithPath: "/var/mobile/Library/Preferences", isDirectory: true)))

        var report: [String] = []
        for (label, dir) in candidates {
            let url = dir.appendingPathComponent("fa_probe.txt")
            do {
                try Data("ok".utf8).write(to: url)
                try? FileManager.default.removeItem(at: url)
                report.append("\(label)=OK")
            } catch {
                let ns = error as NSError
                report.append("\(label)=ERR\(ns.code)")
            }
        }
        return report.joined(separator: " ")
    }
}
