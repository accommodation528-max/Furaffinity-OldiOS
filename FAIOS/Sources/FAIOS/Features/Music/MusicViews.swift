import SwiftUI
import FAPages

/// 详情页里的播放卡片（音乐投稿）。
struct MusicCard: View {

    let detail: FASubmissionDetail

    @ObservedObject private var player = FAAudioPlayer.shared

    private var isCurrent: Bool { player.submissionID == detail.id }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artworkView
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.title)
                        .font(.subheadline).bold()
                        .lineLimit(1)
                    Text(detail.authorName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if isCurrent, player.isLoading {
                        Text("正在下载…").font(.caption2).foregroundColor(.secondary)
                    } else if isCurrent, let error = player.errorText {
                        Text(error).font(.caption2).foregroundColor(.red).lineLimit(2)
                    }
                }

                Spacer(minLength: 6)

                Button {
                    guard let url = detail.musicURL else { return }
                    player.toggle(
                        id: detail.id,
                        url: url,
                        title: detail.title,
                        artist: detail.authorName,
                        artworkURL: detail.previewURL ?? detail.imageURL
                    )
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: 42, height: 42)
                        if isCurrent && player.isLoading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if isCurrent, player.duration > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { min(player.currentTime, player.duration) },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.1)
                    )
                    .accentColor(.orange)

                    HStack {
                        Text(Self.time(player.currentTime))
                        Spacer()
                        Text(Self.time(player.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let url = detail.previewURL ?? detail.imageURL {
            RemoteImage(url: url, contentMode: .fill, maxPixelSize: 200)
        } else {
            ZStack {
                Color.secondary.opacity(0.14)
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 全局小播放条：挂在 TabView 上方，切到别的 tab 也能控制
struct MiniPlayerBar: View {

    @ObservedObject private var player = FAAudioPlayer.shared

    var body: some View {
        if player.submissionID != nil {
            HStack(spacing: 10) {
                artwork
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title)
                        .font(.caption).bold()
                        .lineLimit(1)
                    if player.duration > 0 {
                        ProgressView(value: min(player.currentTime, player.duration), total: player.duration)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                            .frame(height: 2)
                    }
                }

                Button {
                    if player.isPlaying { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = player.artwork {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.14)
                Image(systemName: "music.note").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
