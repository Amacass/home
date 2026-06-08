import SwiftUI
import AVKit
import Photos

/// 1本の動画を読み込み、自動再生＆ループ再生する。
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var isReady = false
    @Published var muted = true

    private var endObserver: NSObjectProtocol?
    private var requestID: PHImageRequestID?
    private var loadedID: String?

    init() {
        player.actionAtItemEnd = .none
        player.isMuted = muted
    }

    func load(asset: PHAsset) {
        // 同じ動画なら作り直さない
        if loadedID == asset.localIdentifier, player.currentItem != nil {
            player.play()
            return
        }
        unload()
        loadedID = asset.localIdentifier

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud上の動画もDLして再生
        options.deliveryMode = .automatic

        requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
            guard let item else { return }
            Task { @MainActor in
                guard let self, self.loadedID == asset.localIdentifier else { return }
                self.player.replaceCurrentItem(with: item)
                self.player.isMuted = self.muted
                self.player.play()
                self.isReady = true
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.player.seek(to: .zero)
                    self.player.play()
                }
            }
        }
    }

    func toggleMute() {
        muted.toggle()
        player.isMuted = muted
    }

    func pause() { player.pause() }

    func unload() {
        player.pause()
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        isReady = false
        loadedID = nil
    }

    deinit {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    }
}

/// AVPlayerLayer を SwiftUI に出す（コントロール無し）。
struct AssetPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
