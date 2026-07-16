import MediaPlayer
import SwiftUI
import UIKit

/// デッキ（1本の「ながれ」）の共通インターフェース。
/// - ながれ A: `DeckPlayer`（AVAudioPlayer ベース。独立音量に対応、DRM フリー曲のみ）
/// - ながれ B: `MusicDeckPlayer`（システムのミュージックプレイヤー。Apple Music を含む全曲に対応）
@MainActor
protocol DeckControlling: AnyObject, ObservableObject {
    var label: String { get }
    /// デッキの特性を説明する短い注記
    var subtitle: String { get }
    var tint: Color { get }

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

    /// ピッカーでクラウド上の曲（Apple Music など）を表示してよいか
    var allowsCloudItems: Bool { get }
    /// 選曲時に再生できず除外した曲数
    var skippedCount: Int { get }
    /// 再生開始に失敗したときのエラーメッセージ（UI がアラート表示後に nil へ戻す）
    var errorMessage: String? { get set }

    func load(_ items: [MPMediaItem])
    func play()
    func pause()
    func toggle()
    func next()
    func previous()
    /// スリープタイマーのフェード係数（音量操作に対応するデッキのみ反映）
    func setFade(_ value: Double)
}
