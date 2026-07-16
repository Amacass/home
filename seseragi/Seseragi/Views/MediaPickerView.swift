import MediaPlayer
import SwiftUI

/// iPhone の「ミュージック」ライブラリから曲を選ぶピッカー。
/// MPMediaPickerController の SwiftUI ラッパー。
struct MediaPickerView: UIViewControllerRepresentable {

    let prompt: String
    /// クラウド上の曲（Apple Music など）を表示するか。
    /// ファイル再生のデッキ（ながれ A）では再生できないため隠し、
    /// システムプレイヤーのデッキ（ながれ B）では表示する。
    let showsCloudItems: Bool
    let onPicked: ([MPMediaItem]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = showsCloudItems
        picker.prompt = prompt
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        private let parent: MediaPickerView

        init(_ parent: MediaPickerView) { self.parent = parent }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            parent.onPicked(mediaItemCollection.items)
            parent.dismiss()
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.dismiss()
        }
    }
}
