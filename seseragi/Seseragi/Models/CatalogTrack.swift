import Foundation

/// Apple Music カタログ検索で選んだ1曲を表す軽量モデル。
/// MusicKit の Song から、再生に必要な最小限（カタログID）と表示用情報だけを取り出す。
/// MusicKit に依存させないため、ここには標準型（String / URL）のみを持つ。
struct CatalogTrack: Identifiable, Equatable {
    /// Apple Music カタログのストアID（`Song.id.rawValue`）。
    /// これを MPMusicPlayerStoreQueueDescriptor に渡して再生する。
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}
