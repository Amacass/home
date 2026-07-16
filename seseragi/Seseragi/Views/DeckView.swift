import MediaPlayer
import SwiftUI

/// 1つの「ながれ」（デッキ）の操作カード。
/// 曲情報・進行バー・再生操作・リピート・音量スライダー・選曲を担う。
/// DeckControlling に適合するどのデッキ（AVAudioPlayer 系 / システムプレイヤー系）でも使える。
struct DeckView<Deck: DeckControlling>: View {

    @ObservedObject var deck: Deck
    /// 選曲を開始する（親が適切なピッカー/検索シートを提示する）
    let onSelect: () -> Void

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
            volumeArea
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(deck.tint.opacity(0.35), lineWidth: 1)
        )
        .alert("お知らせ", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deck.errorMessage ?? "")
        }
    }

    /// deck.errorMessage の有無をアラート表示にマップする（閉じたら nil に戻す）
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { deck.errorMessage != nil },
            set: { isPresented in
                if !isPresented { deck.errorMessage = nil }
            }
        )
    }

    // MARK: - パーツ

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(deck.label, systemImage: "water.waves")
                    .font(.headline)
                    .foregroundStyle(deck.tint)
                Text(deck.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onSelect()
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
                Text(deck.currentTitle ?? "不明な曲")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(deck.currentArtist ?? "不明なアーティスト")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(deck.positionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = deck.artworkImage {
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
            onSelect()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 40))
                Text(deck.selectionPrompt)
                    .font(.subheadline)
            }
            .foregroundStyle(deck.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var volumeArea: some View {
        if deck.supportsVolume {
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
        } else {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                Text("音量は本体の音量ボタンと連動。バランスはもう一方のながれ側で調整してください。")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
