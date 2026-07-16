import Foundation

/// おやすみタイマー。指定時間が経過すると両方のデッキを
/// ゆっくりフェードアウトさせてから一時停止する。
/// （フェードは音量操作に対応するデッキのみ。システムプレイヤーのデッキは停止のみ）
@MainActor
final class SleepTimer: ObservableObject {

    static let presetMinutes = [15, 30, 45, 60, 90]

    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isActive = false

    private let decks: [any DeckControlling]
    private var timer: Timer?
    /// フェードアウトにかける秒数
    private let fadeDuration: TimeInterval = 20

    init(decks: [any DeckControlling]) {
        self.decks = decks
    }

    var remainingText: String {
        let total = max(Int(remaining), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func start(minutes: Int) {
        cancel()
        remaining = TimeInterval(minutes * 60)
        isActive = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remaining = 0
        // フェード係数を元に戻す（ユーザー設定音量には触れない）
        decks.forEach { $0.setFade(1.0) }
    }

    private func tick() {
        remaining -= 1
        if remaining <= fadeDuration {
            // 残り時間に比例して音量をゆっくり絞る
            let scale = max(remaining / fadeDuration, 0)
            decks.forEach { $0.setFade(scale) }
        }
        if remaining <= 0 {
            decks.forEach { $0.pause() }
            cancel()
        }
    }
}
