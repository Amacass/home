import Foundation
import Combine
import AVFAudio

/// オーディオ出力経路（ルート）の変化を監視し、Bluetoothイヤホンの切断を検知する。
///
/// iOSではClassic Bluetoothのオーディオ機器（AirPods等）はCoreBluetoothでは扱えないため、
/// `AVAudioSession` のルート変更通知でイヤホンの抜けを検知するのが確実。
final class AudioRouteMonitor: ObservableObject {
    /// 現在つながっているBluetoothオーディオ機器名（なければ nil）。
    @Published private(set) var connectedDeviceName: String?

    /// 切断を検知したときに呼ばれる。引数は切断されたデバイス名。常にメインスレッドで呼ばれる。
    var onDisconnect: ((String) -> Void)?

    private let bluetoothPortTypes: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothLE, .bluetoothHFP
    ]

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

        if reason == .oldDeviceUnavailable,
           let previousRoute = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            let disconnectedBluetooth = previousRoute.outputs.first {
                bluetoothPortTypes.contains($0.portType)
            }
            if let device = disconnectedBluetooth {
                let name = device.portName
                DispatchQueue.main.async { [weak self] in
                    self?.onDisconnect?(name)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateConnectedDevice()
        }
    }

    private func updateConnectedDevice() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        connectedDeviceName = outputs.first { bluetoothPortTypes.contains($0.portType) }?.portName
    }
}
