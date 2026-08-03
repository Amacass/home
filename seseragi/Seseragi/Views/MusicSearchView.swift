import MusicKit
import SwiftUI

/// ながれ B の選曲画面。
/// - 「検索」タブ: Apple Music カタログ全体を検索（曲・プレイリスト・アルバム・アーティスト）
/// - 「ライブラリ」タブ: 自分のライブラリ（プレイリスト・アーティスト・アルバム・曲）を閲覧
/// どちらからでも曲を複数選択でき、「決定」でまとめて Song の配列として返す。
struct MusicSearchView: View {

    let tint: Color
    let onDone: ([Song]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var selection = SongSelection()
    @State private var mode: BrowseMode = .library
    @State private var authStatus = MusicAuthorization.currentStatus

    private enum BrowseMode {
        case search
        case library
    }

    var body: some View {
        NavigationStack {
            Group {
                switch authStatus {
                case .authorized:
                    browser
                case .notDetermined:
                    ProgressView("準備中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    authDeniedView
                }
            }
            .navigationTitle("Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定\(selection.songs.isEmpty ? "" : "（\(selection.songs.count)）")") {
                        onDone(selection.songs)
                        dismiss()
                    }
                    .disabled(selection.songs.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .navigationDestination(for: BrowseTarget.self) { target in
                switch target {
                case .libraryPlaylists, .libraryArtists, .libraryAlbums:
                    LibraryContainerList(kind: target, tint: tint)
                default:
                    SongListView(target: target, tint: tint)
                }
            }
        }
        .tint(tint)
        .environmentObject(selection)
        .task {
            if authStatus == .notDetermined {
                authStatus = await MusicAuthorization.request()
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $mode) {
                Text("ライブラリ").tag(BrowseMode.library)
                Text("検索").tag(BrowseMode.search)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            switch mode {
            case .search:
                CatalogSearchTab(tint: tint)
            case .library:
                LibraryRootTab(tint: tint)
            }
        }
    }

    private var authDeniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text("Apple Music へのアクセスが必要です")
                .font(.headline)
            Text("ライブラリの閲覧とカタログ検索のために、設定でこのアプリに「メディアと Apple Music」へのアクセスを許可してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
        }
        .padding(28)
    }
}

// MARK: - 検索タブ

/// Apple Music カタログ検索。曲に加えプレイリスト・アルバム・アーティストも表示し、
/// コンテナは中に入って曲を選べる。
private struct CatalogSearchTab: View {

    let tint: Color
    @EnvironmentObject private var selection: SongSelection

    @State private var term = ""
    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        List {
            SelectedSongsSection(tint: tint)

            if isSearching {
                HStack { ProgressView(); Text("検索中…").foregroundStyle(.secondary) }
            } else if let searchError {
                Text(searchError).foregroundStyle(.secondary).font(.callout)
            } else if term.isEmpty {
                Text("曲名・アーティスト名・プレイリスト名で検索")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if songs.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty {
                Text("該当が見つかりませんでした").foregroundStyle(.secondary)
            }

            if !songs.isEmpty {
                Section("曲") {
                    ForEach(songs) { song in
                        SongRow(song: song, tint: tint)
                    }
                }
            }
            if !playlists.isEmpty {
                Section("プレイリスト") {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: BrowseTarget.playlist(playlist)) {
                            ContainerRow(artwork: playlist.artwork,
                                         title: playlist.name,
                                         subtitle: playlist.curatorName ?? "プレイリスト")
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("アルバム") {
                    ForEach(albums) { album in
                        NavigationLink(value: BrowseTarget.album(album)) {
                            ContainerRow(artwork: album.artwork,
                                         title: album.title,
                                         subtitle: album.artistName)
                        }
                    }
                }
            }
            if !artists.isEmpty {
                Section("アーティスト") {
                    ForEach(artists) { artist in
                        NavigationLink(value: BrowseTarget.catalogArtist(artist)) {
                            ContainerRow(artwork: artist.artwork,
                                         title: artist.name,
                                         subtitle: "アーティスト")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $term,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "曲・アーティスト・プレイリスト")
        .task(id: term) {
            await search()
        }
    }

    /// 入力が落ち着いてから（350ms）検索する。term 変更で自動キャンセルされる。
    private func search() async {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            songs = []; playlists = []; albums = []; artists = []
            searchError = nil
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(
                term: text,
                types: [Song.self, Playlist.self, Album.self, Artist.self]
            )
            request.limit = 8
            let response = try await request.response()
            if Task.isCancelled { return }
            songs = Array(response.songs)
            playlists = Array(response.playlists)
            albums = Array(response.albums)
            artists = Array(response.artists)
        } catch {
            if Task.isCancelled { return }
            searchError = "検索に失敗しました: \(error.localizedDescription)"
            songs = []; playlists = []; albums = []; artists = []
        }
    }
}

// MARK: - ライブラリタブ

/// 自分のライブラリの入口。プレイリスト / アーティスト / アルバム / 曲 へ辿れる。
private struct LibraryRootTab: View {

    let tint: Color

    var body: some View {
        List {
            SelectedSongsSection(tint: tint)

            Section("ライブラリ") {
                NavigationLink(value: BrowseTarget.libraryPlaylists) {
                    Label("プレイリスト", systemImage: "music.note.list")
                }
                NavigationLink(value: BrowseTarget.libraryArtists) {
                    Label("アーティスト", systemImage: "music.mic")
                }
                NavigationLink(value: BrowseTarget.libraryAlbums) {
                    Label("アルバム", systemImage: "square.stack")
                }
                NavigationLink(value: BrowseTarget.allLibrarySongs) {
                    Label("曲", systemImage: "music.note")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
