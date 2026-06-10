import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalFluidView(analyzer: model.analyzer)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            if showControls {
                controlBar
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black)
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button(action: toggleCapture) {
                Label(isCapturing ? "停止" : "開始", systemImage: isCapturing ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private var isCapturing: Bool {
        if case .capturing = model.capture.state { return true }
        if case .starting = model.capture.state { return true }
        return false
    }

    private var statusText: String {
        switch model.capture.state {
        case .idle:
            return "「開始」を押すと、Macで再生中の音楽に反応します。（画面をクリックでこのバーを隠せます）"
        case .starting:
            return "音声キャプチャを開始しています…"
        case .capturing:
            return "🎵 再生中の音に反応しています"
        case .failed(let message):
            return "⚠️ \(message)"
        }
    }

    private func toggleCapture() {
        if isCapturing {
            model.capture.stop()
        } else {
            model.capture.start()
        }
    }
}
