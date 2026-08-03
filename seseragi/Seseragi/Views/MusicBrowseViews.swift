import MusicKit
import SwiftUI

// MARK: - 選択モデル

/// 選曲画面全体で共有する「選択中の曲」。選んだ順序を保つ。
@MainActor
final class SongSelection: ObservableObject {
    @Published var songs: [Song] = []

    func contains(_ song: Song) -> Bool {
        songs.contains { $0.id == song.id }
    }

    func toggle(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs.remove(at: index)
        } else {
            songs.append(song)
        }
    }

    func addAll(_ newSongs: [Song]) {
        for song in newSongs where !contains(song) {
            songs.append(song)
        }
    }
}

// MARK: - ナビゲーション先

/// 選曲画面のナビゲーション先。
/// 曲一覧に落ちる終端（プレイリスト・アルバム・アーティスト・全曲）と、
/// ライブラリの中間一覧（プレイリスト一覧など）の両方を表す。
enum BrowseTarget: Hashable {
    case playlist(Playlist)
    case album(Album)
    /// カタログのアーティスト（人気曲を表示）
    case catalogArtist(Artist)
    /// ライブラリのアーティスト（ライブラリ内のその人の曲を表示）
    case libraryArtist(Artist)
    case allLibrarySongs
    case libraryPlaylists
    case libraryArtists
    case libraryAlbums
}

// MARK: - 曲一覧（終端）

/// コンテナ（プレイリスト・アルバム・アーティスト・全曲）の中の曲を一覧表示し、
/// 個別選択と「すべて追加」に対応する。
struct SongListView: View {

    let target: BrowseTarget
    let tint: Color

    @EnvironmentObject private var selection: SongSelection
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("読み込み中…").foregroundStyle(.secondary) }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary).font(.callout)
            } else if songs.isEmpty {
                Text("曲がありません").foregroundStyle(.secondary)
            } else {
                Section {
                    Button {
                        selection.addAll(songs)
                    } label: {
                        Label("この \(songs.count) 曲をすべて追加", systemImage: "text.badge.plus")
                            .fontWeight(.semibold)
                    }
                }
                Section {
                    ForEach(songs) { song in
                        SongRow(song: song, tint: tint)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private var title: String {
        switch target {
        case .playlist(let playlist): return playlist.name
        case .album(let album): return album.title
        case .catalogArtist(let artist), .libraryArtist(let artist): return artist.name
        case .allLibrarySongs: return "すべての曲"
        default: return ""
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            switch target {
            case .playlist(let playlist):
                let detailed = try await playlist.with([.tracks])
                let tracks = detailed.tracks.map(Array.init) ?? []
                songs = tracks.compactMap { track in
                    if case let .song(song) = track { return song }
                    return nil
                }
            case .album(let album):
                let detailed = try await album.with([.tracks])
                let tracks = detailed.tracks.map(Array.init) ?? []
                songs = tracks.compactMap { track in
                    if case let .song(song) = track { return song }
                    return nil
                }
            case .catalogArtist(let artist):
                let detailed = try await artist.with([.topSongs])
                songs = detailed.topSongs.map(Array.init) ?? []
            case .libraryArtist(let artist):
                var request = MusicLibraryRequest<Song>()
                request.filter(matching: \.artistName, equalTo: artist.name)
                request.sort(by: \.title, ascending: true)
                songs = Array(try await request.response().items)
            case .allLibrarySongs:
                var request = MusicLibraryRequest<Song>()
                request.sort(by: \.title, ascending: true)
                request.limit = 1000
                songs = Array(try await request.response().items)
            default:
                songs = []
            }
        } catch {
            loadError = "読み込みに失敗しました: \(error.localizedDescription)"
        }
    }
}

// MARK: - ライブラリの中間一覧

/// ライブラリのプレイリスト / アーティスト / アルバムの一覧。
/// 行をタップすると SongListView（曲一覧）へ進む。
struct LibraryContainerList: View {

    let kind: BrowseTarget
    let tint: Color

    @State private var playlists: [Playlist] = []
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("読み込み中…").foregroundStyle(.secondary) }
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary).font(.callout)
            } else if playlists.isEmpty && artists.isEmpty && albums.isEmpty {
                Text("項目がありません").foregroundStyle(.secondary)
            }

            ForEach(playlists) { playlist in
                NavigationLink(value: BrowseTarget.playlist(playlist)) {
                    ContainerRow(artwork: playlist.artwork,
                                 title: playlist.name,
                                 subtitle: "プレイリスト")
                }
            }
            ForEach(artists) { artist in
                NavigationLink(value: BrowseTarget.libraryArtist(artist)) {
                    ContainerRow(artwork: artist.artwork,
                                 title: artist.name,
                                 subtitle: "アーティスト")
                }
            }
            ForEach(albums) { album in
                NavigationLink(value: BrowseTarget.album(album)) {
                    ContainerRow(artwork: album.artwork,
                                 title: album.title,
                                 subtitle: album.artistName)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private var title: String {
        switch kind {
        case .libraryPlaylists: return "プレイリスト"
        case .libraryArtists: return "アーティスト"
        case .libraryAlbums: return "アルバム"
        default: return ""
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            switch kind {
            case .libraryPlaylists:
                var request = MusicLibraryRequest<Playlist>()
                request.sort(by: \.name, ascending: true)
                playlists = Array(try await request.response().items)
            case .libraryArtists:
                var request = MusicLibraryRequest<Artist>()
                request.sort(by: \.name, ascending: true)
                artists = Array(try await request.response().items)
            case .libraryAlbums:
                var request = MusicLibraryRequest<Album>()
                request.sort(by: \.title, ascending: true)
                albums = Array(try await request.response().items)
            default:
                break
            }
        } catch {
            loadError = "読み込みに失敗しました: \(error.localizedDescription)"
        }
    }
}

// MARK: - 行部品

/// 曲1行。タップで選択のオン/オフ。
struct SongRow: View {

    let song: Song
    let tint: Color
    @EnvironmentObject private var selection: SongSelection

    var body: some View {
        Button {
            selection.toggle(song)
        } label: {
            HStack(spacing: 12) {
                if let artwork = song.artwork {
                    ArtworkImage(artwork, width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    artworkPlaceholder
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.body).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: selection.contains(song) ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(selection.contains(song) ? tint : Color.secondary)
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 44, height: 44)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary).font(.caption))
    }
}

/// プレイリスト・アルバム・アーティストなどコンテナ1行。
struct ContainerRow: View {

    let artwork: Artwork?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            if let artwork {
                ArtworkImage(artwork, width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary).font(.caption))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 選択中の曲のセクション（両タブの先頭に表示）。タップで解除できる。
struct SelectedSongsSection: View {

    let tint: Color
    @EnvironmentObject private var selection: SongSelection

    var body: some View {
        if !selection.songs.isEmpty {
            Section("選択中（\(selection.songs.count)曲・上から順に再生）") {
                ForEach(selection.songs) { song in
                    SongRow(song: song, tint: tint)
                }
            }
        }
    }
}
