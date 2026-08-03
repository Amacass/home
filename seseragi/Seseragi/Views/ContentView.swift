import MediaPlayer
import SwiftUI

struct ContentView: View {

    /// ながれ A: ファイル再生（独立音量対応・端末内の DRM フリー曲）
    @StateObject private var deckA: DeckPlayer
    /// ながれ B: システムプレイヤー（Apple Music・DRM 曲対応・音量は本体連動）
    @StateObject private var deckB: MusicDeckPlayer
    @StateObject private var sleepTimer: SleepTimer

    @State private var authStatus = MPMediaLibrary.authorizationStatus()
    /// ながれ A: 端末内ライブラリのピッカー
    @State private var showLibraryPicker = false
    /// ながれ B: Apple Music カタログ検索
    @State private var showMusicSearch = false

    init() {
        let a = DeckPlayer(label: "ながれ A", tint: Color(red: 0.45, green: 0.85, blue: 0.95))
        let b = MusicDeckPlayer(label: "ながれ B", tint: Color(red: 0.55, green: 0.95, blue: 0.75))
        _deckA = StateObject(wrappedValue: a)
        _deckB = StateObject(wrappedValue: b)
        _sleepTimer = StateObject(wrappedValue: SleepTimer(decks: [a, b]))
    }

    private var allDecks: [any DeckControlling] { [deckA, deckB] }

    var body: some View {
        ZStack {
            // 選曲シートの表示中は波のアニメーションを止めて描画負荷を下げる
            WaterBackground(paused: showLibraryPicker || showMusicSearch)

            VStack(spacing: 16) {
                header

                if authStatus == .authorized {
                    DeckView(deck: deckA) { showLibraryPicker = true }
                    DeckView(deck: deckB) { showMusicSearch = true }
                    Spacer(minLength: 0)
                    bottomBar
                } else {
                    Spacer()
                    permissionView
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLibraryPicker) {
            MediaPickerView(
                prompt: "「ながれ A」で流す曲を選ぶ",
                showsCloudItems: deckA.allowsCloudItems
            ) { items in
                deckA.load(items)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showMusicSearch) {
            MusicSearchView(tint: deckB.tint) { songs in
                deckB.load(songs)
            }
        }
        .onAppear {
            // ハブが管理するのは AVAudioPlayer 系のデッキのみ。
            // ながれ B（システムプレイヤー）は Music アプリ自身が
            // 割り込みやロック画面表示を処理する。
            PlaybackHub.shared.register(decks: [deckA])
            requestAuthorizationIfNeeded()
        }
    }

    // MARK: - パーツ

    private var header: some View {
        VStack(spacing: 2) {
            Text("せせらぎ")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
            Text("ふたつの流れを、かさねて眠る")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var bottomBar: some View {
        HStack {
            allPlayButton
            Spacer()
            sleepTimerMenu
        }
    }

    private var anyPlaying: Bool { deckA.isPlaying || deckB.isPlaying }

    private var allPlayButton: some View {
        Button {
            let pauseAll = anyPlaying
            for deck in allDecks where deck.hasQueue {
                pauseAll ? deck.pause() : deck.play()
            }
        } label: {
            Label(anyPlaying ? "すべて一時停止" : "すべて再生",
                  systemImage: anyPlaying ? "pause.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.teal.opacity(0.7))
        .disabled(!deckA.hasQueue && !deckB.hasQueue)
    }

    private var sleepTimerMenu: some View {
        Menu {
            if sleepTimer.isActive {
                Button("タイマーを解除", role: .destructive) { sleepTimer.cancel() }
            }
            ForEach(SleepTimer.presetMinutes, id: \.self) { minutes in
                Button("\(minutes) 分後に停止") { sleepTimer.start(minutes: minutes) }
            }
        } label: {
            Label(
                sleepTimer.isActive ? "おやすみ \(sleepTimer.remainingText)" : "おやすみタイマー",
                systemImage: "moon.zzz.fill"
            )
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.indigo)
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house")
                .font(.system(size: 44))
                .foregroundStyle(.teal)
            Text("ミュージックライブラリへのアクセスが必要です")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("iPhone の「ミュージック」に入っている曲を選んで再生するために、ライブラリへのアクセスを許可してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if authStatus == .denied || authStatus == .restricted {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.03, green: 0.11, blue: 0.15).opacity(0.75))
        )
        .foregroundStyle(.white)
    }

    private func requestAuthorizationIfNeeded() {
        guard authStatus == .notDetermined else { return }
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                authStatus = status
            }
        }
    }
}

#Preview {
    ContentView()
}
