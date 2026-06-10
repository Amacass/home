import SwiftUI

@main
struct FluidWaveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// Owns the long-lived audio + visual pieces so they survive view reloads.
@MainActor
final class AppModel: ObservableObject {
    let analyzer = AudioAnalyzer()
    let capture: AudioCaptureManager
    let engine: VisualEngine

    init() {
        capture = AudioCaptureManager(analyzer: analyzer)
        guard let engine = VisualEngine(analyzer: analyzer) else {
            fatalError("Metal is not available on this Mac")
        }
        self.engine = engine
    }
}
