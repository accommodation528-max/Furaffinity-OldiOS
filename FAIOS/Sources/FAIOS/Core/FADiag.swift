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
        let report = writableDirectories().map { label, url, ok in
            ok ? "\(label)=OK \(url.path)" : "\(label)=ERR"
        }
        return report.isEmpty ? "(no candidates)" : report.joined(separator: " ")
    }

    /// 挨个试写，返回 (标签, 目录, 是否可写)
    static func writableDirectories() -> [(String, URL, Bool)] {
        var candidates: [(String, URL)] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(("Documents", docs))
        }
        candidates.append(("tmp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)))
        candidates.append(("home", URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)))
        candidates.append(("caches", FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/var/mobile/Library/Caches", isDirectory: true)))
        candidates.append(("var/tmp", URL(fileURLWithPath: "/var/tmp", isDirectory: true)))
        candidates.append(("var/mobile", URL(fileURLWithPath: "/var/mobile", isDirectory: true)))
        candidates.append(("media", URL(fileURLWithPath: "/var/mobile/Media", isDirectory: true)))
        candidates.append(("prefs", URL(fileURLWithPath: "/var/mobile/Library/Preferences", isDirectory: true)))

        var results: [(String, URL, Bool)] = []
        for (label, dir) in candidates {
            let url = dir.appendingPathComponent("fa_probe.txt")
            do {
                try Data("ok".utf8).write(to: url)
                try? FileManager.default.removeItem(at: url)
                results.append((label, dir, true))
            } catch {
                results.append((label, dir, false))
            }
        }
        return results
    }

    /// 真机是唯一有登录态的机器：把几个「需要登录才看得到结构」的页面抓下来存到可写目录，
    /// 再用 SSH 取回 PC，作为解析层的真实 fixture（离线就能写测试）。
    static func exportPages(_ requests: [(String, URL)]) async -> String {
        guard let target = writableDirectories().first(where: { $0.2 })?.1 else {
            return "没有可写目录：\n" + probeWritablePaths()
        }
        var lines: [String] = ["目录 \(target.path)"]
        for (name, url) in requests {
            do {
                let html = try await FAFetch.html(url)
                let file = target.appendingPathComponent("fa_\(name).html")
                try html.data(using: .utf8)?.write(to: file)
                lines.append("\(name) ✓ \(html.utf8.count)B → \(file.lastPathComponent)")
            } catch {
                lines.append("\(name) ✗ \(error)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
