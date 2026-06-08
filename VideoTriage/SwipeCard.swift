import SwiftUI
import Photos

/// 動画カード。右(上)へスワイプ=いらない / 左(上)へスワイプ=いる。
struct SwipeCard: View {
    let asset: PHAsset
    /// trash == true なら「いらない」
    let onDecision: (_ trash: Bool) -> Void

    @StateObject private var controller = PlayerController()
    @State private var drag: CGSize = .zero
    @State private var gone = false

    private let threshold: CGFloat = 110

    /// -1.0(完全に左/いる) 〜 +1.0(完全に右/いらない)
    private var progress: CGFloat {
        max(-1, min(1, drag.width / threshold))
    }

    var body: some View {
        ZStack {
            // 動画
            AssetPlayerView(player: controller.player)
                .background(Color.black)

            if !controller.isReady {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }

            // ミュート切り替え（右下）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        controller.toggleMute()
                    } label: {
                        Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .padding(16)
                }
            }

            // スワイプ中のラベル
            stamp(text: "いらない", color: .red, side: .right)
                .opacity(Double(max(0, progress)))
            stamp(text: "いる", color: .green, side: .left)
                .opacity(Double(max(0, -progress)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(borderColor, lineWidth: abs(progress) > 0.05 ? 4 : 0)
        )
        .offset(x: drag.width, y: drag.height)
        .rotationEffect(.degrees(Double(drag.width / 22)))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard !gone else { return }
                    drag = value.translation
                }
                .onEnded { value in
                    guard !gone else { return }
                    if value.translation.width > threshold {
                        fly(trash: true)
                    } else if value.translation.width < -threshold {
                        fly(trash: false)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            drag = .zero
                        }
                    }
                }
        )
        .onAppear { controller.load(asset: asset) }
        .onDisappear { controller.unload() }
    }

    // MARK: - ボタンからも呼べる外部トリガー
    // （ContentView 側のボタン用に Notification は使わず、ここはジェスチャ専用）

    private var borderColor: Color {
        if progress > 0 { return .red }
        if progress < 0 { return .green }
        return .clear
    }

    private enum Side { case left, right }

    private func stamp(text: String, color: Color, side: Side) -> some View {
        VStack {
            HStack {
                if side == .right { Spacer() }
                Text(text)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(color)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(color, lineWidth: 4)
                    )
                    .rotationEffect(.degrees(side == .right ? 12 : -12))
                    .padding(28)
                if side == .left { Spacer() }
            }
            Spacer()
        }
    }

    private func fly(trash: Bool) {
        gone = true
        controller.pause()
        let target = CGSize(width: trash ? 1200 : -1200, height: -260)
        withAnimation(.easeOut(duration: 0.22)) {
            drag = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            onDecision(trash)
        }
    }
}
