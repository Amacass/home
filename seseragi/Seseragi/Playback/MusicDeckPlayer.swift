import MediaPlayer
import SwiftUI
import UIKit

/// システムのミュージックプレイヤー（Music アプリのエンジン）を使うデッキ。
/// Apple Music のストリーミング曲・DRM 保護曲・未ダウンロードのクラウド曲を含む、
/// ライブラリのすべての曲を再生できる。
///
/// 制約:
/// - iOS の仕様によりアプリ内の独立音量調整は不可（iPhone 本体の音量と連動）
/// - 再生キューは Music アプリと共有される（Music アプリ側にも再生状態が表示される）
///
/// systemMusicPlayer を採用する理由: applicationMusicPlayer / applicationQueuePlayer は
/// アプリがバックグラウンドに移ると再生が止まるため、就寝用途に耐えない。
@MainActor
final class MusicDeckPlayer: ObservableObject, DeckControlling {

    let label: String
    let subtitle = "Apple Music対応・音量は本体と連動"
    let tint: Color

    @Published private(set) var items: [MPMediaItem] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlayingItem: MPMediaItem?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .playlist {
        didSet { applyRepeatMode() }
    }

    // このデッキはすべての曲を再生できるため、除外は発生しない
    let skippedCount = 0
    let supportsVolume = false
    var volume: Double = 1.0 // 未使用（プロトコル要件）
    let allowsCloudItems = true

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(label: String, tint: Color) {
        self.label = label
        self.tint = tint

        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncState() }
        })
        observers.append(center.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncState() }
        })
    }

    // MARK: - DeckControlling

    var hasQueue: Bool { !items.isEmpty }

    var positionText: String {
        guard hasQueue else { return "" }
        let index = player.indexOfNowPlayingItem
        guard index != NSNotFound, index < items.count else {
            return "\(items.count) 曲"
        }
        return "\(index + 1) / \(items.count) 曲"
    }

    var currentTitle: String? { nowPlayingItem?.title }
    var currentArtist: String? { nowPlayingItem?.artist }

    var artworkImage: UIImage? {
        nowPlayingItem?.artwork?.image(at: CGSize(width: 112, height: 112))
    }

    var duration: TimeInterval {
        nowPlayingItem?.playbackDuration ?? 0
    }

    /// 選んだ曲をそのままキューにする。DRM の除外は不要（全曲再生可能）。
    func load(_ picked: [MPMediaItem]) {
        guard !picked.isEmpty else { return }
        items = picked
        player.setQueue(with: MPMediaItemCollection(items: picked))
        applyRepeatMode()
        player.play()
        syncState()
    }

    func play() {
        guard hasQueue || player.nowPlayingItem != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func next() {
        player.skipToNextItem()
    }

    func previous() {
        // 3秒以上再生していたら曲頭に戻る（一般的なプレイヤーの挙動）
        if player.currentPlaybackTime > 3 {
            player.skipToBeginning()
        } else {
            player.skipToPreviousItem()
        }
    }

    func setFade(_ value: Double) {
        // システムプレイヤーは音量操作ができないため、フェードは適用しない。
        // スリープタイマー終了時の pause() のみが作用する。
    }

    // MARK: - 内部処理

    private func applyRepeatMode() {
        switch repeatMode {
        case .playlist: player.repeatMode = .all
        case .single: player.repeatMode = .one
        case .off: player.repeatMode = .none
        }
    }

    private func syncState() {
        isPlaying = (player.playbackState == .playing)
        nowPlayingItem = player.nowPlayingItem
        syncProgress()
        if isPlaying {
            startProgressTimer()
        } else {
            stopProgressTimer()
        }
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
        let time = player.currentPlaybackTime
        currentTime = time.isFinite && time >= 0 ? time : 0
    }
}
