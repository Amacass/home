import Foundation
import Combine
import AVFAudio

/// オーディオ出力経路（ルート）の変化を監視し、Bluetoothイヤホンの切断を検知する。
///
/// iOSではClassic Bluetoothのオーディオ機器（AirPods等）はCoreBluetoothでは扱えないため、
/// `AVAudioSession` のルート変更通知でイヤホンの抜けを検知する。
///
/// 「耳から外しただけ」での誤検知をできるだけ避けるため、切断候補を検知しても
/// すぐには確定せず、`confirmationDelay` 秒の猶予を置く。猶予中に同じ機器が
/// 再接続（newDeviceAvailable）したら、その記録はキャンセルする。
/// これにより、一瞬の経路の揺れや機器の切り替え時の誤記録を抑える。
final class AudioRouteMonitor: ObservableObject {
    /// 現在つながっているBluetoothオーディオ機器名（なければ nil）。
    @Published private(set) var connectedDeviceName: String?

    /// 切断を確定したときに呼ばれる。引数は切断されたデバイス名。常にメインスレッドで呼ばれる。
    var onDisconnect: ((String) -> Void)?

    /// 切断確定までの猶予（秒）。この間に再接続すればキャンセルする。
    var confirmationDelay: TimeInterval = 6

    private let bluetoothPortTypes: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothLE, .bluetoothHFP
    ]

    /// 確定待ちの切断（デバイス名 -> キャンセル可能な処理）。
    private var pendingDisconnects: [String: DispatchWorkItem] = [:]

    func start() {
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers で他アプリ（Apple Music / Spotify等）の再生を邪魔せずに
        // 自分のオーディオセッションをアクティブに保ち、ルート変更通知を受け取れるようにする。
        try? session.setCategory(
            .playback,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(true)

        updateConnectedDevice()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // 直前のルートからBluetooth出力が消えた → 切断候補。
            if let previousRoute = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                let names = previousRoute.outputs
                    .filter { bluetoothPortTypes.contains($0.portType) }
                    .map(\.portName)
                for name in names {
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleDisconnect(deviceName: name)
                    }
                }
            }

        case .newDeviceAvailable:
            // Bluetooth機器が（再）接続された → 同名の確定待ちがあればキャンセル。
            let currentBTNames = AVAudioSession.sharedInstance().currentRoute.outputs
                .filter { bluetoothPortTypes.contains($0.portType) }
                .map(\.portName)
            for name in currentBTNames {
                DispatchQueue.main.async { [weak self] in
                    self?.cancelPending(deviceName: name)
                }
            }

        default:
            break
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateConnectedDevice()
        }
    }

    // MARK: - 切断の確定／キャンセル（メインスレッドで実行）

    private func scheduleDisconnect(deviceName: String) {
        // 既に同名の確定待ちがあれば作り直す（猶予をリセット）。
        pendingDisconnects[deviceName]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDisconnects[deviceName] = nil
            self.onDisconnect?(deviceName)
        }
        pendingDisconnects[deviceName] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmationDelay, execute: work)
    }

    private func cancelPending(deviceName: String) {
        pendingDisconnects[deviceName]?.cancel()
        pendingDisconnects[deviceName] = nil
    }

    private func updateConnectedDevice() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        connectedDeviceName = outputs.first { bluetoothPortTypes.contains($0.portType) }?.portName
    }
}
