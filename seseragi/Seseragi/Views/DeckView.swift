import MediaPlayer
import SwiftUI

/// 1つの「ながれ」（デッキ）の操作カード。
/// 曲情報・進行バー・再生操作・リピート・音量スライダー・選曲を担う。
struct DeckView: View {

    @ObservedObject var deck: DeckPlayer
    @State private var showPicker = false
    @State private var showSkippedAlert = false

    var body: some View {
        VStack(spacing: 14) {
            header
            if deck.hasQueue {
                trackInfo
                progressBar
                controls
            } else {
                emptyState
            }
            volumeSlider
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(deck.tint.opacity(0.35), lineWidth: 1)
        )
        .sheet(isPresented: $showPicker) {
            MediaPickerView(prompt: "「\(deck.label)」で流す曲を選ぶ") { items in
                deck.load(items)
                if deck.skippedCount > 0 {
                    showSkippedAlert = true
                }
            }
            .ignoresSafeArea()
        }
        .alert("再生できない曲がありました", isPresented: $showSkippedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(deck.skippedCount) 曲を除外しました。Apple Music のストリーミング曲など DRM 保護された曲は、2つ同時の再生には使えません。購入した曲や CD から取り込んだ曲をお使いください。")
        }
    }

    // MARK: - パーツ

    private var header: some View {
        HStack {
            Label(deck.label, systemImage: "water.waves")
                .font(.headline)
                .foregroundStyle(deck.tint)
            Spacer()
            Button {
                showPicker = true
            } label: {
                Label("選曲", systemImage: "music.note.list")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(deck.tint)
        }
    }

    private var trackInfo: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.currentItem?.title ?? "不明な曲")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(deck.currentItem?.artist ?? "不明なアーティスト")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(deck.currentIndex + 1) / \(deck.items.count) 曲")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = deck.currentItem?.artwork?.image(at: CGSize(width: 112, height: 112)) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(deck.tint.opacity(0.25))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "music.note").foregroundStyle(deck.tint))
        }
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(deck.tint)
                        .frame(width: max(geo.size.width * progress, 0))
                }
            }
            .frame(height: 4)
            HStack {
                Text(timeText(deck.currentTime))
                Spacer()
                Text(timeText(deck.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var progress: CGFloat {
        guard deck.duration > 0 else { return 0 }
        return CGFloat(min(deck.currentTime / deck.duration, 1))
    }

    private var controls: some View {
        HStack {
            Button {
                deck.repeatMode = deck.repeatMode.nextMode
            } label: {
                Image(systemName: deck.repeatMode.systemImage)
                    .font(.title3)
                    .foregroundStyle(deck.repeatMode.isActive ? deck.tint : Color.secondary)
            }
            .accessibilityLabel(deck.repeatMode.label)

            Spacer()

            Button {
                deck.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            Button {
                deck.toggle()
            } label: {
                Image(systemName: deck.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(deck.tint)
            }
            .padding(.horizontal, 18)

            Button {
                deck.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            Spacer()

            // リピートボタンと左右対称にするためのダミー
            Image(systemName: "repeat")
                .font(.title3)
                .opacity(0)
        }
    }

    private var emptyState: some View {
        Button {
            showPicker = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 40))
                Text("ミュージックから曲を選ぶ")
                    .font(.subheadline)
            }
            .foregroundStyle(deck.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $deck.volume, in: 0...1)
                .tint(deck.tint)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
