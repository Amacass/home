import Combine
import Foundation
import MusicKit
import SwiftUI
import UIKit

/// MusicKit の SystemMusicPlayer（Music アプリのエンジン）を使うデッキ。
/// Apple Music カタログの曲もライブラリの曲（プレイリスト・アーティスト経由を含む）も、
/// Song をそのまま渡すだけで再生できる。ストリーミング曲・DRM 保護曲対応。
///
/// 制約:
/// - iOS の仕様によりアプリ内の独立音量調整は不可（iPhone 本体の音量と連動）
/// - 再生キューは Music アプリと共有される（Music アプリ側にも再生状態が表示される）
///
/// SystemMusicPlayer を採用する理由: ApplicationMusicPlayer は
/// アプリがバックグラウンドに移ると再生が止まるため、就寝用途に耐えない。
@MainActor
final class MusicDeckPlayer: ObservableObject, DeckControlling {

    let label: String
    let subtitle = "Apple Music・ライブラリ対応 / 音量は本体と連動"
    let selectionPrompt = "Apple Music から選ぶ"
    let tint: Color

    @Published private(set) var songs: [Song] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentArtist: String?
    @Published private(set) var artworkImage: UIImage?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var positionText = ""
    @Published var repeatMode: RepeatMode = .playlist {
        didSet { applyRepeatMode() }
    }
    @Published var errorMessage: String?

    let supportsVolume = false
    var volume: Double = 1.0 // 未使用（プロトコル要件）

    private let player = SystemMusicPlayer.shared
    private var progressTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// アートワークの再取得を防ぐキャッシュ（URL キー）
    private static let artworkCache = NSCache<NSURL, UIImage>()
    private var artworkTask: Task<Void, Never>?
    private var currentArtworkURL: URL?

    init(label: String, tint: Color) {
        self.label = label
        self.tint = tint

        // MusicKit プレイヤーの状態変化（再生/停止・曲替わり）を監視する
        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in self?.syncState() }
            }
            .store(in: &cancellables)
        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in self?.syncState() }
            }
            .store(in: &cancellables)
    }

    // MARK: - DeckControlling

    var hasQueue: Bool { !songs.isEmpty }

    /// 選んだ曲（カタログ・ライブラリ混在可）をキューにして再生を始める。
    func load(_ picked: [Song]) {
        guard !picked.isEmpty else { return }
        songs = picked
        player.queue = SystemMusicPlayer.Queue(for: picked)
        Task {
            do {
                try await player.play()
                applyRepeatMode()
            } catch {
                errorMessage = "再生を開始できませんでした: \(error.localizedDescription)\n\nApple Music のサブスクリプションが有効か、通信状況を確認してください。"
            }
            syncState()
        }
    }

    func play() {
        guard hasQueue else { return }
        Task {
            try? await player.play()
            syncState()
        }
    }

    func pause() {
        player.pause()
        syncState()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func next() {
        Task {
            try? await player.skipToNextEntry()
            syncState()
        }
    }

    func previous() {
        // 3秒以上再生していたら曲頭に戻る（一般的なプレイヤーの挙動）
        if player.playbackTime > 3 {
            player.playbackTime = 0
            syncProgress()
            return
        }
        Task {
            try? await player.skipToPreviousEntry()
            syncState()
        }
    }

    func setFade(_ value: Double) {
        // システムプレイヤーは音量操作ができないため、フェードは適用しない。
        // スリープタイマー終了時の pause() のみが作用する。
    }

    // MARK: - 内部処理

    private func applyRepeatMode() {
        switch repeatMode {
        case .playlist: player.state.repeatMode = .all
        case .single: player.state.repeatMode = .one
        case .off: player.state.repeatMode = MusicPlayer.RepeatMode.none
        }
    }

    private func syncState() {
        isPlaying = (player.state.playbackStatus == .playing)

        if let entry = player.queue.currentEntry {
            currentTitle = entry.title.isEmpty ? nil : entry.title
            currentArtist = entry.subtitle
            if case let .song(song)? = entry.item {
                duration = song.duration ?? 0
                if currentArtist == nil || currentArtist?.isEmpty == true {
                    currentArtist = song.artistName
                }
            } else {
                duration = 0
            }
            updatePositionText(for: entry)
            loadArtwork(entry.artwork)
        } else {
            currentTitle = nil
            currentArtist = nil
            duration = 0
            positionText = songs.isEmpty ? "" : "\(songs.count) 曲"
            artworkImage = nil
            currentArtworkURL = nil
        }

        syncProgress()
        if isPlaying {
            startProgressTimer()
        } else {
            stopProgressTimer()
        }
    }

    private func updatePositionText(for entry: MusicPlayer.Queue.Entry) {
        let entries = player.queue.entries
        var position: Int?
        for (index, candidate) in entries.enumerated() where candidate.id == entry.id {
            position = index + 1
            break
        }
        if let position {
            positionText = "\(position) / \(entries.count) 曲"
        } else {
            positionText = "\(entries.count) 曲"
        }
    }

    private func loadArtwork(_ artwork: Artwork?) {
        guard let url = artwork?.url(width: 120, height: 120) else {
            artworkImage = nil
            currentArtworkURL = nil
            return
        }
        guard url != currentArtworkURL else { return }
        currentArtworkURL = url

        if let cached = Self.artworkCache.object(forKey: url as NSURL) {
            artworkImage = cached
            return
        }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            Self.artworkCache.setObject(image, forKey: url as NSURL)
            await MainActor.run {
                guard let self, self.currentArtworkURL == url else { return }
                self.artworkImage = image
            }
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
        let time = player.playbackTime
        currentTime = time.isFinite && time >= 0 ? time : 0
    }
}
