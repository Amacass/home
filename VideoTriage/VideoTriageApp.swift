import SwiftUI
import AVFoundation

@main
struct VideoTriageApp: App {
    init() {
        // サイレントモードでも音を鳴らす（不要なら無音でも判断できるが一応）
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
