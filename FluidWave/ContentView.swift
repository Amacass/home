import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalFluidView(engine: model.engine)
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

            Button {
                model.engine.requestNextScene()
            } label: {
                Label("シーン", systemImage: "arrow.triangle.2.circlepath")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)

            EngineStatusView(engine: model.engine)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
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

/// Live scene name + estimated BPM (observes the engine directly).
private struct EngineStatusView: View {
    @ObservedObject var engine: VisualEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.sceneName)
                .font(.headline)
                .foregroundStyle(.white)
            Text(engine.bpmText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(minWidth: 130, alignment: .leading)
    }
}
