import MediaPlayer
import SwiftUI
import UIKit

/// システムのミュージックプレイヤー（Music アプリのエンジン）を使うデッキ。
/// Apple Music カタログ検索で選んだ曲を、ストアID経由で再生する。
/// ストリーミング曲・DRM 保護曲を含むすべての曲に対応する。
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
    let selectionPrompt = "Apple Music を検索"
    let tint: Color

    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlayingItem: MPMediaItem?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .playlist {
        didSet { applyRepeatMode() }
    }
    @Published var errorMessage: String?

    let supportsVolume = false
    var volume: Double = 1.0 // 未使用（プロトコル要件）

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// 現在のキューの曲数（表示用）
    private var queueCount = 0
    /// ストアID → 表示情報。nowPlayingItem のメタデータが揃うまでのフォールバックに使う
    private var catalogDisplay: [String: CatalogTrack] = [:]
    /// 再生開始直後、nowPlayingItem がまだ無いときに見せる先頭曲
    private var firstFallback: CatalogTrack?

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

    var hasQueue: Bool { queueCount > 0 || nowPlayingItem != nil }

    var positionText: String {
        guard queueCount > 0 else { return "" }
        let index = player.indexOfNowPlayingItem
        guard index != NSNotFound, index < queueCount else {
            return "\(queueCount) 曲"
        }
        return "\(index + 1) / \(queueCount) 曲"
    }

    var currentTitle: String? {
        if let title = nowPlayingItem?.title, !title.isEmpty { return title }
        return currentFallback?.title
    }

    var currentArtist: String? {
        if let artist = nowPlayingItem?.artist, !artist.isEmpty { return artist }
        return currentFallback?.artist
    }

    var artworkImage: UIImage? {
        nowPlayingItem?.artwork?.image(at: CGSize(width: 112, height: 112))
    }

    var duration: TimeInterval {
        nowPlayingItem?.playbackDuration ?? 0
    }

    /// 表示のフォールバック元。再生中の曲のストアIDに対応する検索結果、
    /// なければ先頭曲。
    private var currentFallback: CatalogTrack? {
        if let id = nowPlayingItem?.playbackStoreID, let track = catalogDisplay[id] {
            return track
        }
        return firstFallback
    }

    /// カタログ検索で選んだ曲をキューにして再生を始める。
    func loadCatalog(_ tracks: [CatalogTrack]) {
        guard !tracks.isEmpty else { return }
        catalogDisplay = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        firstFallback = tracks.first
        queueCount = tracks.count

        let ids = tracks.map(\.id)
        player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: ids))
        applyRepeatMode()

        // setQueue 直後の play() は失敗することがあるため、準備完了を待ってから再生する
        player.prepareToPlay { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = "再生を開始できませんでした: \(error.localizedDescription)\n\nApple Music のサブスクリプションが有効か、通信状況（ストリーミング可否）を確認してください。"
                }
                self.player.play()
                self.syncState()
            }
        }
    }

    func play() {
        guard hasQueue else { return }
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
