import MusicKit
import SwiftUI

/// Apple Music カタログ全体を検索して曲を選ぶ画面。
/// 標準の MPMediaPickerController と違い、ライブラリに未追加の曲でも検索・選択できる。
/// 選んだ曲（複数可）は CatalogTrack として返す。
struct MusicSearchView: View {

    let tint: Color
    let onDone: ([CatalogTrack]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var term = ""
    @State private var results: [CatalogTrack] = []
    /// 選択した曲（選んだ順を保つ）
    @State private var selected: [CatalogTrack] = []
    @State private var authStatus = MusicAuthorization.currentStatus
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch authStatus {
                case .authorized:
                    searchContent
                case .notDetermined:
                    ProgressView("準備中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    authDeniedView
                }
            }
            .navigationTitle("Apple Music を検索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定\(selected.isEmpty ? "" : "（\(selected.count)）")") {
                        onDone(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(tint)
        .task {
            if authStatus == .notDetermined {
                authStatus = await MusicAuthorization.request()
            }
        }
    }

    // MARK: - 検索本体

    private var searchContent: some View {
        List {
            if !selected.isEmpty {
                Section("選択中（\(selected.count)曲・上から順に再生）") {
                    ForEach(selected) { track in
                        row(for: track, isSelected: true)
                    }
                }
            }
            Section {
                if isSearching {
                    HStack { ProgressView(); Text("検索中…").foregroundStyle(.secondary) }
                } else if let searchError {
                    Text(searchError).foregroundStyle(.secondary).font(.callout)
                } else if results.isEmpty && !term.isEmpty {
                    Text("該当する曲が見つかりませんでした").foregroundStyle(.secondary)
                }
                ForEach(results) { track in
                    row(for: track, isSelected: selected.contains(track))
                }
            } header: {
                Text(term.isEmpty ? "曲名・アーティスト名で検索" : "検索結果")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $term, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "曲名・アーティスト名")
        .task(id: term) {
            await debouncedSearch()
        }
    }

    private func row(for track: CatalogTrack, isSelected: Bool) -> some View {
        Button {
            toggle(track)
        } label: {
            HStack(spacing: 12) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isSelected ? tint : Color.secondary)
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    private func artwork(for track: CatalogTrack) -> some View {
        AsyncImage(url: track.artworkURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary).font(.caption))
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 動作

    private func toggle(_ track: CatalogTrack) {
        if let index = selected.firstIndex(of: track) {
            selected.remove(at: index)
        } else {
            selected.append(track)
        }
    }

    /// 入力が落ち着いてから（300ms）検索する。term 変更で自動キャンセルされる。
    private func debouncedSearch() async {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(term: text, types: [Song.self])
            request.limit = 25
            let response = try await request.response()
            if Task.isCancelled { return }
            results = response.songs.map { song in
                CatalogTrack(
                    id: song.id.rawValue,
                    title: song.title,
                    artist: song.artistName,
                    artworkURL: song.artwork?.url(width: 100, height: 100)
                )
            }
        } catch {
            if Task.isCancelled { return }
            searchError = "検索に失敗しました: \(error.localizedDescription)"
            results = []
        }
    }

    // MARK: - 権限

    private var authDeniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text("Apple Music へのアクセスが必要です")
                .font(.headline)
            Text("カタログを検索して再生するために、設定でこのアプリに「メディアと Apple Music」へのアクセスを許可してください。Apple Music のサブスクリプションも必要です。")
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
