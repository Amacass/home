import MediaPlayer
import SwiftUI
import UIKit

/// デッキ（1本の「ながれ」）の共通インターフェース。
/// - ながれ A: `DeckPlayer`（AVAudioPlayer ベース。独立音量に対応、端末内の DRM フリー曲）
/// - ながれ B: `MusicDeckPlayer`（システムプレイヤー + Apple Music カタログ検索。全曲対応）
///
/// 「どうやって曲を選ぶか」はデッキごとに異なる（ライブラリピッカー / カタログ検索）ため、
/// 選曲の提示は親（ContentView）が担当し、このプロトコルには含めない。
/// デッキ共通の「再生・表示・リピート・音量」だけを抽象化する。
@MainActor
protocol DeckControlling: AnyObject, ObservableObject {
    var label: String { get }
    /// デッキの特性を説明する短い注記
    var subtitle: String { get }
    var tint: Color { get }
    /// 選曲ボタン・空状態に出す文言（「ミュージックから選ぶ」/「Apple Music を検索」など）
    var selectionPrompt: String { get }

    var hasQueue: Bool { get }
    var positionText: String { get }
    var isPlaying: Bool { get }
    var currentTitle: String? { get }
    var currentArtist: String? { get }
    var artworkImage: UIImage? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    var repeatMode: RepeatMode { get set }

    /// このデッキがアプリ内の独立音量に対応しているか
    /// （システムプレイヤーは iOS の制約で非対応。本体音量と連動する）
    var supportsVolume: Bool { get }
    var volume: Double { get set }

    /// 選曲・再生開始に失敗したときのメッセージ（UI がアラート表示後に nil へ戻す）
    var errorMessage: String? { get set }

    func play()
    func pause()
    func toggle()
    func next()
    func previous()
    /// スリープタイマーのフェード係数（音量操作に対応するデッキのみ反映）
    func setFade(_ value: Double)
}
