import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import FAPages

/// 音乐投稿的播放器。
///
/// FA 的音乐投稿是一个 `<audio src>` 直链（`d.furaffinity.net/...mp3`），
/// 直接把它交给 `AVAudioPlayer` 播是不行的 —— 那个直链也要过 Cloudflare 和 cookie，
/// 所以先用 `FAFetch.data` 把整首歌下载下来落到可写目录，再从文件播。
///
/// 锁屏 / 控制中心：`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`。
/// 想在后台继续播，Info.plist 必须带 `UIBackgroundModes: [audio]` ——
/// xtool 生成的 Info.plist 没有这一项，所以 `scripts/patch-ipa.py` 在打包后补上。
@MainActor
final class FAAudioPlayer: NSObject, ObservableObject {

    static let shared = FAAudioPlayer()

    @Published private(set) var submissionID: Int?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var errorText: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var fileURL: URL?

    private override init() {
        super.init()
        configureSession()
        registerRemoteCommands()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - 播放控制

    /// 点「播放」：已经在放这首就暂停；换了另一首就下载并播新的
    func toggle(id: Int, url: URL, title: String, artist: String, artworkURL: URL?) {
        if submissionID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                refreshNowPlaying()
            } else {
                activateSession()
                player.play()
                isPlaying = true
                startTimer()
                refreshNowPlaying()
            }
            return
        }
        load(id: id, url: url, title: title, artist: artist, artworkURL: artworkURL)
    }

    func play(id: Int, url: URL, title: String, artist: String, artworkURL: URL?) {
        guard submissionID != id || player == nil else {
            resume()
            return
        }
        load(id: id, url: url, title: title, artist: artist, artworkURL: artworkURL)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        refreshNowPlaying()
    }

    func resume() {
        guard let player else { return }
        activateSession()
        player.play()
        isPlaying = true
        startTimer()
        refreshNowPlaying()
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        currentTime = player.currentTime
        refreshNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        player?.stop()
        player = nil
        stopTimer()
        isPlaying = false
        isLoading = false
        submissionID = nil
        duration = 0
        currentTime = 0
        fileURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 载入

    private func load(id: Int, url: URL, title: String, artist: String, artworkURL: URL?) {
        loadTask?.cancel()
        player?.stop()
        stopTimer()

        submissionID = id
        self.title = title
        self.artist = artist
        duration = 0
        currentTime = 0
        errorText = nil
        isLoading = true
        isPlaying = false
        artwork = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await Self.download(id: id, url: url)
                try Task.checkCancellation()

                let player = try AVAudioPlayer(contentsOf: file)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
                self.fileURL = file
                self.duration = player.duration
                self.currentTime = 0
                self.isLoading = false

                self.activateSession()
                player.play()
                self.isPlaying = true
                self.startTimer()

                // 封面（有就用，没有就不显示；失败不影响播放）
                if let artworkURL,
                   let image = try? await FAImageCache.shared.image(for: artworkURL, maxPixelSize: 600) {
                    self.artwork = image
                }
                self.refreshNowPlaying()
            } catch is CancellationError {
                // 用户换了另一首 / 关掉了页面，安静退出
            } catch {
                self.isLoading = false
                self.isPlaying = false
                self.errorText = FAErrorMessage.describe(error)
            }
        }
    }

    /// 下载到可写目录（这台机器上只有 /var/tmp 之类的位置可写，见 `FAStore`）
    private static func download(id: Int, url: URL) async throws -> URL {
        let directory = FAWritableDirectory.directory("audio")
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        if let directory {
            let target = directory.appendingPathComponent("\(id).\(ext)")
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int ?? 0
            if size > 4096 { return target }   // 之前下过，直接用
            let data = try await FAFetch.data(url)
            try data.write(to: target, options: .atomic)
            return target
        }
        // 没找到可写目录就退化成临时文件（能不能写看运气）
        let data = try await FAFetch.data(url)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).\(ext)")
        try data.write(to: target, options: .atomic)
        return target
    }

    // MARK: - 会话

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            pause()
        }
    }

    // MARK: - 进度

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        duration = player.duration
        if !player.isPlaying {
            isPlaying = false
            stopTimer()
            refreshNowPlaying()
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying { self.pause() } else { self.resume() }
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func refreshNowPlaying() {
        guard let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension FAAudioPlayer: AVAudioPlayerDelegate {

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
            self.refreshNowPlaying()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.isPlaying = false
            self.errorText = error.map { String(describing: $0) } ?? "解码失败"
            self.stopTimer()
        }
    }
}
