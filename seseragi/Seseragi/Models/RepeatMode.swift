import Foundation

/// 繰り返しモード。デッキごとに独立して設定できる。
enum RepeatMode: CaseIterable {
    /// プレイリスト全体を繰り返す
    case playlist
    /// 現在の一曲を繰り返す
    case single
    /// 繰り返しなし（プレイリストの最後で停止）
    case off

    /// ボタンタップで巡回する次のモード
    var nextMode: RepeatMode {
        switch self {
        case .playlist: return .single
        case .single: return .off
        case .off: return .playlist
        }
    }

    var systemImage: String {
        switch self {
        case .playlist: return "repeat"
        case .single: return "repeat.1"
        case .off: return "repeat"
        }
    }

    var label: String {
        switch self {
        case .playlist: return "プレイリストを繰り返す"
        case .single: return "この曲を繰り返す"
        case .off: return "繰り返しなし"
        }
    }

    var isActive: Bool { self != .off }
}
