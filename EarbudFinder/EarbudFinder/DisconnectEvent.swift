import Foundation
import CoreLocation

/// Bluetoothイヤホンの接続が切れた瞬間に記録される1件のイベント。
struct DisconnectEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    /// 切断されたデバイス名（例: "ぼくのAirPods Pro"）
    let deviceName: String
    let latitude: Double
    let longitude: Double
    /// 記録時点の水平精度（メートル）。負の値は位置が取得できなかったことを示す。
    let horizontalAccuracy: Double

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        deviceName: String,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) {
        self.id = id
        self.date = date
        self.deviceName = deviceName
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 有効な位置情報が記録されているか。
    var hasValidLocation: Bool {
        horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid(coordinate)
    }
}
