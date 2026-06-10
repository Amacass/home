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

/// Owns the long-lived audio pieces so they survive view reloads.
@MainActor
final class AppModel: ObservableObject {
    let analyzer = AudioAnalyzer()
    let capture: AudioCaptureManager

    init() {
        capture = AudioCaptureManager(analyzer: analyzer)
    }
}
