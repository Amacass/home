import Photos
import SwiftUI

/// 写真ライブラリの動画を取得し、「いる / いらない」の振り分け状態を管理する。
@MainActor
final class VideoLibrary: ObservableObject {

    enum AuthState {
        case unknown    // まだ許可を求めていない
        case denied     // 拒否された
        case authorized // 許可された（limited含む）
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newestFirst = "新しい順"
        case oldestFirst = "古い順"
        var id: String { rawValue }
    }

    /// いる動画を振り分けるアルバム名
    static let keepAlbumName = "いる"

    @Published var authState: AuthState = .unknown
    @Published var assets: [PHAsset] = []
    @Published var index: Int = 0
    @Published private(set) var trashIDs: [String] = []   // いらない判定の localIdentifier
    @Published private(set) var keepIDs: [String] = []    // いる判定の localIdentifier
    @Published var sortOrder: SortOrder = .newestFirst
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var isFiling = false

    /// Undo 用の履歴
    private struct Decision { let assetID: String; let wasTrash: Bool }
    private var history: [Decision] = []

    var current: PHAsset? {
        guard index >= 0, index < assets.count else { return nil }
        return assets[index]
    }

    /// 次に再生する動画（先読み用）
    var next: PHAsset? {
        let n = index + 1
        guard n >= 0, n < assets.count else { return nil }
        return assets[n]
    }

    var total: Int { assets.count }
    var processed: Int { min(index, assets.count) }
    var isFinished: Bool { !assets.isEmpty && index >= assets.count }
    var trashCount: Int { trashIDs.count }
    var keepCount: Int { keepIDs.count }
    var canUndo: Bool { !history.isEmpty }

    var trashAssets: [PHAsset] {
        let set = Set(trashIDs)
        return assets.filter { set.contains($0.localIdentifier) }
    }

    var keepAssets: [PHAsset] {
        let set = Set(keepIDs)
        return assets.filter { set.contains($0.localIdentifier) }
    }

    // MARK: - アクセス許可

    func requestAccess() {
        // 既存の許可状態を先に確認
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            authState = .authorized
            loadVideos()
            return
        case .denied, .restricted:
            authState = .denied
            return
        default:
            break
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    self.authState = .authorized
                    self.loadVideos()
                default:
                    self.authState = .denied
                }
            }
        }
    }

    // MARK: - 読み込み

    func loadVideos() {
        isLoading = true
        let order = sortOrder
        Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d",
                                            PHAssetMediaType.video.rawValue)
            switch order {
            case .newestFirst:
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            case .oldestFirst:
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            }
            let result = PHAsset.fetchAssets(with: .video, options: options)
            var arr: [PHAsset] = []
            arr.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in arr.append(asset) }

            await MainActor.run {
                self.assets = arr
                self.index = 0
                self.trashIDs = []
                self.keepIDs = []
                self.history = []
                self.isLoading = false
            }
        }
    }

    // MARK: - 振り分け

    func decide(trash: Bool) {
        guard let asset = current else { return }
        if trash {
            trashIDs.append(asset.localIdentifier)
        } else {
            keepIDs.append(asset.localIdentifier)
        }
        history.append(Decision(assetID: asset.localIdentifier, wasTrash: trash))
        index += 1
    }

    func undo() {
        guard let last = history.popLast() else { return }
        if last.wasTrash {
            if let i = trashIDs.lastIndex(of: last.assetID) { trashIDs.remove(at: i) }
        } else {
            if let i = keepIDs.lastIndex(of: last.assetID) { keepIDs.remove(at: i) }
        }
        index = max(0, index - 1)
    }

    func restart() {
        loadVideos()
    }

    // MARK: - 「いる」アルバムへ振り分け

    /// 「いる」アルバムを取得（無ければ作成）して返す。
    private func fetchOrCreateKeepAlbum(completion: @escaping (PHAssetCollection?) -> Void) {
        if let existing = existingKeepAlbum() {
            completion(existing)
            return
        }
        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.keepAlbumName)
            placeholder = req.placeholderForCreatedAssetCollection
        } completionHandler: { success, _ in
            guard success, let id = placeholder?.localIdentifier else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil).firstObject
            DispatchQueue.main.async { completion(collection) }
        }
    }

    private func existingKeepAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", Self.keepAlbumName)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options).firstObject
    }

    /// いる動画を「いる」アルバムへ追加する。
    func fileKeepsToAlbum(completion: @escaping (Bool) -> Void) {
        let toFile = keepAssets
        guard !toFile.isEmpty else { completion(true); return }
        isFiling = true
        fetchOrCreateKeepAlbum { [weak self] album in
            guard let self, let album else {
                self?.isFiling = false
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                guard let req = PHAssetCollectionChangeRequest(for: album) else { return }
                // 既にアルバムにある動画を二重追加しない
                let already = PHAsset.fetchAssets(in: album, options: nil)
                var existing = Set<String>()
                already.enumerateObjects { a, _, _ in existing.insert(a.localIdentifier) }
                let adding = toFile.filter { !existing.contains($0.localIdentifier) }
                if !adding.isEmpty {
                    req.addAssets(adding as NSArray)
                }
            } completionHandler: { success, _ in
                Task { @MainActor in
                    self.isFiling = false
                    completion(success)
                }
            }
        }
    }

    // MARK: - 削除（システムの確認ダイアログが出る）

    func deleteTrash(completion: @escaping (Bool) -> Void) {
        let toDelete = trashAssets
        guard !toDelete.isEmpty else { completion(true); return }
        isDeleting = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
        } completionHandler: { success, _ in
            Task { @MainActor in
                self.isDeleting = false
                if success {
                    // 削除済みは一覧からも除く
                    let removed = Set(self.trashIDs)
                    self.assets.removeAll { removed.contains($0.localIdentifier) }
                    self.trashIDs = []
                }
                completion(success)
            }
        }
    }
}
