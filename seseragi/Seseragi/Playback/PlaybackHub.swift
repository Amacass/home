import AVFoundation
import MediaPlayer

/// アプリ全体の再生基盤。
/// - AVAudioSession の設定（バックグラウンド再生・割り込み処理）
/// - ロック画面 / コントロールセンターのリモートコマンド
/// - Now Playing 情報の更新
@MainActor
final class PlaybackHub {

    static let shared = PlaybackHub()

    private(set) var decks: [DeckPlayer] = []
    private var configured = false

    private init() {}

    func register(decks: [DeckPlayer]) {
        self.decks = decks
        guard !configured else { return }
        configured = true
        configureSession()
        configureRemoteCommands()
        observeInterruptions()
    }

    func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.decks.forEach { if $0.hasQueue { $0.play() } }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.decks.forEach { $0.pause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let anyPlaying = self.decks.contains { $0.isPlaying }
                self.decks.forEach { deck in
                    if anyPlaying {
                        deck.pause()
                    } else if deck.hasQueue {
                        deck.play()
                    }
                }
            }
            return .success
        }
        // 2デッキのどちらを指すか曖昧なため曲送りは無効化する
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began else { return }
            // 就寝用途のため、割り込み後の自動再開はせず安全側に倒す
            Task { @MainActor in
                PlaybackHub.shared.decks.forEach { $0.pause() }
            }
        }
    }

    /// ロック画面に表示する Now Playing 情報。
    /// システムの Now Playing は1系統しか扱えないため、
    /// 両デッキの曲名を連結した代表情報を表示する。
    func refreshNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let loaded = decks.filter { $0.currentItem != nil }

        guard !loaded.isEmpty else {
            center.nowPlayingInfo = nil
            return
        }

        let playing = decks.filter { $0.isPlaying }
        let titles = loaded.compactMap { $0.currentItem?.title ?? "不明な曲" }
        let representative = playing.first ?? loaded[0]

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: titles.joined(separator: " ✕ "),
            MPMediaItemPropertyArtist: "せせらぎ",
            MPNowPlayingInfoPropertyPlaybackRate: playing.isEmpty ? 0.0 : 1.0,
            MPMediaItemPropertyPlaybackDuration: representative.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: representative.currentTime,
        ]
        if let artwork = representative.currentItem?.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
    }
}
