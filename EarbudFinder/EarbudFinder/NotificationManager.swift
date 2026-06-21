import Foundation
import UserNotifications

/// 切断を記録したことをローカル通知でユーザーに知らせる。
enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    static func notifyDisconnect(deviceName: String, hasLocation: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "イヤホンの接続が切れました"
        content.body = hasLocation
            ? "\(deviceName) の最後の位置を記録しました。アプリで確認できます。"
            : "\(deviceName) が切断されました（位置情報は取得できませんでした）。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // 即時通知
        )
        UNUserNotificationCenter.current().add(request)
    }
}
