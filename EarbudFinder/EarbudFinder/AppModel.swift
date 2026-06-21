import Foundation
import Combine
import SwiftUI

/// アプリ全体を束ねるモデル。位置・オーディオ監視・保存を連携させる。
@MainActor
final class AppModel: ObservableObject {
    let store = DisconnectStore()
    let location = LocationManager()
    let audio = AudioRouteMonitor()
    private let keepAlive = KeepAliveAudio()

    /// バックグラウンドで検知し続けるための無音再生をON/OFFする設定（既定ON）。
    /// ObservableObject内での @AppStorage の挙動の不確実さを避けるため、UserDefaultsを直接扱う。
    @Published var keepAliveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(keepAliveEnabled, forKey: Self.keepAliveKey)
            applyKeepAlive()
        }
    }

    @Published private(set) var hasStarted = false

    private static let keepAliveKey = "keepAliveEnabled"
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 未設定なら既定ON。
        if UserDefaults.standard.object(forKey: Self.keepAliveKey) == nil {
            keepAliveEnabled = true
        } else {
            keepAliveEnabled = UserDefaults.standard.bool(forKey: Self.keepAliveKey)
        }
        audio.onDisconnect = { [weak self] deviceName in
            self?.recordDisconnect(deviceName: deviceName)
        }

        // ネストした ObservableObject の変更を親へ転送し、ViewのUI更新を伝播させる。
        for publisher in [store.objectWillChange, location.objectWillChange, audio.objectWillChange] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// 起動時に一度だけ呼び、各種許可リクエストと監視を開始する。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        location.requestAuthorization()
        NotificationManager.requestAuthorization()
        audio.start()
        applyKeepAlive()
    }

    private func applyKeepAlive() {
        if keepAliveEnabled {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }

    /// 切断を検知したときの記録処理。現在の位置を添えてイベントを保存し、通知する。
    func recordDisconnect(deviceName: String) {
        let loc = location.lastLocation
        let event = DisconnectEvent(
            deviceName: deviceName,
            latitude: loc?.coordinate.latitude ?? 0,
            longitude: loc?.coordinate.longitude ?? 0,
            horizontalAccuracy: loc?.horizontalAccuracy ?? -1
        )
        store.add(event)
        NotificationManager.notifyDisconnect(
            deviceName: deviceName,
            hasLocation: event.hasValidLocation
        )
    }

    /// 動作確認用: いま接続中（または直近の）デバイスとして手動で1件記録する。
    func recordTestEvent() {
        let name = audio.connectedDeviceName ?? "テスト記録"
        recordDisconnect(deviceName: name)
    }
}
