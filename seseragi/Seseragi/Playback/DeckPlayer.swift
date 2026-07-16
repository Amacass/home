import AVFoundation
import MediaPlayer
import SwiftUI

/// AVAudioPlayer ベースのデッキ。
/// ミュージックライブラリから選んだ端末内の曲をファイルとして再生する。
/// アプリ内の独立音量調整・フェードに対応する（DRM 保護曲は再生できない）。
@MainActor
final class DeckPlayer: NSObject, ObservableObject, DeckControlling {

    let label: String
    let subtitle = "端末内の曲・独立音量ミックス対応"
    let tint: Color

    let supportsVolume = true
    let allowsCloudItems = false

    @Published private(set) var items: [MPMediaItem] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .playlist
    /// ユーザーが設定するこのデッキの音量（0...1）
    @Published var volume: Double = 0.7 {
        didSet { applyVolume() }
    }
    /// スリープタイマーのフェードアウト用の係数。ユーザー設定音量とは分離して保持する
    @Published var fade: Double = 1.0 {
        didSet { applyVolume() }
    }
    /// DRM 保護などで再生できずに除外した曲数（アラート表示用）
    @Published var skippedCount = 0
    /// 再生開始に失敗したときのエラーメッセージ（UI がアラート表示する）
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    init(label: String, tint: Color) {
        self.label = label
        self.tint = tint
        super.init()
    }

    var currentItem: MPMediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var hasQueue: Bool { !items.isEmpty }

    var positionText: String {
        guard hasQueue else { return "" }
        return "\(currentIndex + 1) / \(items.count) 曲"
    }

    var currentTitle: String? { currentItem?.title }
    var currentArtist: String? { currentItem?.artist }

    var artworkImage: UIImage? {
        currentItem?.artwork?.image(at: CGSize(width: 112, height: 112))
    }

    func setFade(_ value: Double) {
        fade = value
    }

    // MARK: - キュー操作

    /// ミュージックピッカーで選んだ曲をこのデッキのキューにして再生を始める。
    /// 事前に除外するのは「ファイルの実体が端末になく URL が取れない曲」のみ。
    /// それ以外はできる限り再生を試み、失敗した曲は再生時にスキップする。
    func load(_ picked: [MPMediaItem]) {
        let playable = picked.filter { $0.assetURL != nil }
        skippedCount = picked.count - playable.count
        items = playable
        currentIndex = 0
        if playable.isEmpty {
            stop()
        } else {
            startCurrent(autoplay: true)
        }
    }

    // MARK: - 再生操作

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard hasQueue else { return }
        guard let player else {
            startCurrent(autoplay: true)
            return
        }
        PlaybackHub.shared.activateSession()
        player.play()
        isPlaying = true
        startProgressTimer()
        PlaybackHub.shared.refreshNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        syncProgress()
        stopProgressTimer()
        PlaybackHub.shared.refreshNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopProgressTimer()
        PlaybackHub.shared.refreshNowPlaying()
    }

    func next() {
        guard hasQueue else { return }
        currentIndex = (currentIndex + 1) % items.count
        startCurrent(autoplay: isPlaying)
    }

    func previous() {
        guard hasQueue else { return }
        // 3秒以上再生していたら曲頭に戻る（一般的なプレイヤーの挙動）
        if currentTime > 3 {
            player?.currentTime = 0
            currentTime = 0
            return
        }
        currentIndex = (currentIndex - 1 + items.count) % items.count
        startCurrent(autoplay: isPlaying)
    }

    // MARK: - 内部処理

    private func startCurrent(autoplay: Bool) {
        stopProgressTimer()
        player?.stop()
        player = nil
        currentTime = 0
        duration = 0

        guard let item = currentItem, let url = item.assetURL else {
            isPlaying = false
            PlaybackHub.shared.refreshNowPlaying()
            return
        }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            applyVolume()
            duration = newPlayer.duration
            if autoplay {
                PlaybackHub.shared.activateSession()
                newPlayer.play()
                isPlaying = true
                startProgressTimer()
            } else {
                isPlaying = false
            }
            PlaybackHub.shared.refreshNowPlaying()
        } catch {
            // 読み込みに失敗した曲はキューから外して次へ
            skippedCount += 1
            items.remove(at: currentIndex)
            if items.isEmpty {
                stop()
            } else {
                currentIndex %= items.count
                startCurrent(autoplay: autoplay)
            }
        }
    }

    /// 曲の終端に達したときのリピート処理
    private func trackFinished() {
        guard hasQueue else {
            stop()
            return
        }
        switch repeatMode {
        case .single:
            startCurrent(autoplay: true)
        case .playlist:
            currentIndex = (currentIndex + 1) % items.count
            startCurrent(autoplay: true)
        case .off:
            if currentIndex + 1 < items.count {
                currentIndex += 1
                startCurrent(autoplay: true)
            } else {
                isPlaying = false
                currentTime = duration
                stopProgressTimer()
                PlaybackHub.shared.refreshNowPlaying()
            }
        }
    }

    private func applyVolume() {
        player?.volume = Float(volume * fade)
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func syncProgress() {
        guard let player else { return }
        currentTime = player.currentTime
    }
}

// MARK: - AVAudioPlayerDelegate

extension DeckPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.trackFinished() }
    }
}
