import Foundation
import Combine
import CoreLocation

/// 位置情報の取得を管理する。
/// バックグラウンドでも直近の位置を保持できるよう、常時許可＋バックグラウンド更新を有効にする。
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var lastLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// 「常に許可」をリクエストする。最初は「使用中のみ」が出るので、許可後に常時へ昇格を促す。
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// 位置追跡を開始する。バックグラウンド更新は許可状態が得られてから有効化する。
    func startTracking() {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        // allowsBackgroundLocationUpdates は Background Modes(Location) と
        // WhenInUse/Always 許可がそろっている時のみ true にできる（さもなくばクラッシュ）。
        if status == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopTracking() {
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            // 「使用中のみ」が取れたら、バックグラウンドでも記録できるよう「常に許可」へ昇格を促す。
            manager.requestAlwaysAuthorization()
            startTracking()
        case .authorizedAlways:
            startTracking()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            lastLocation = loc
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 一時的なエラーは無視（位置が取れ次第 didUpdateLocations が呼ばれる）。
    }
}
