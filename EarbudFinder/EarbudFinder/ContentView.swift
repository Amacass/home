import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard()
                    if let latest = model.store.latest {
                        LatestDisconnectCard(event: latest)
                    } else {
                        EmptyStateCard()
                    }
                    HistorySection()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("イヤホン探し")
        }
    }
}

// MARK: - ステータス

private struct StatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: model.audio.connectedDeviceName != nil ? "earbuds" : "earbuds.case")
                        .font(.title2)
                        .foregroundStyle(model.audio.connectedDeviceName != nil ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(model.audio.connectedDeviceName ?? "未接続")
                            .font(.headline)
                        Text(model.audio.connectedDeviceName != nil ? "接続中 — 切れたら自動で記録します" : "Bluetoothイヤホンを接続してください")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Toggle(isOn: $model.keepAliveEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("バックグラウンド監視")
                        Text("他アプリで再生中でも切断を検知（無音再生・電池を消費）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.location.authorizationStatus != .authorizedAlways {
                    LocationWarning(status: model.location.authorizationStatus)
                }
            }
        }
    }
}

private struct LocationWarning: View {
    let status: CLAuthorizationStatus

    private var message: String {
        switch status {
        case .notDetermined: return "位置情報の許可を確認しています…"
        case .denied, .restricted: return "位置情報が許可されていません。設定アプリから「常に許可」にしてください。"
        case .authorizedWhenInUse: return "「Appの使用中のみ許可」です。バックグラウンドで記録するには「常に許可」を推奨します。"
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption.bold())
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 最新の切断位置

private struct LatestDisconnectCard: View {
    let event: DisconnectEvent
    @EnvironmentObject private var model: AppModel
    @State private var camera: MapCameraPosition

    init(event: DisconnectEvent) {
        self.event = event
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: event.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        ))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("最後に切れた場所", systemImage: "mappin.and.ellipse")
                    .font(.headline)

                if event.hasValidLocation {
                    Map(position: $camera) {
                        Marker(event.deviceName, coordinate: event.coordinate)
                            .tint(.red)
                        UserAnnotation()
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    InfoRow(icon: "clock", text: event.date.formatted(date: .abbreviated, time: .shortened))
                    if let distance = distanceText {
                        InfoRow(icon: "figure.walk", text: "現在地からおよそ \(distance)")
                    }
                    InfoRow(icon: "scope", text: "精度 約\(Int(event.horizontalAccuracy))m")

                    Button {
                        openInMaps()
                    } label: {
                        Label("マップで道順を見る", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("\(event.deviceName) が \(event.date.formatted(date: .abbreviated, time: .shortened)) に切断されましたが、位置情報を取得できませんでした。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var distanceText: String? {
        guard let here = model.location.lastLocation else { return nil }
        let there = CLLocation(latitude: event.latitude, longitude: event.longitude)
        let meters = here.distance(from: there)
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: event.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = "\(event.deviceName) が切れた場所"
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }
}

private struct EmptyStateCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("まだ記録はありません")
                    .font(.headline)
                Text("イヤホンの接続が切れると、その場所を自動で記録します。下のボタンで動作確認もできます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    model.recordTestEvent()
                } label: {
                    Label("いまの位置でテスト記録", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 履歴

private struct HistorySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.store.events.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("履歴")
                            .font(.headline)
                        Spacer()
                        Button("すべて消去", role: .destructive) {
                            model.store.clear()
                        }
                        .font(.caption)
                    }
                    ForEach(model.store.events) { event in
                        HistoryRow(event: event)
                        if event.id != model.store.events.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Button {
                model.recordTestEvent()
            } label: {
                Label("いまの位置でテスト記録", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct HistoryRow: View {
    let event: DisconnectEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.hasValidLocation ? "mappin.circle.fill" : "mappin.slash.circle")
                .foregroundStyle(event.hasValidLocation ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.deviceName)
                    .font(.subheadline.weight(.medium))
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.hasValidLocation {
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: event.coordinate))
                    item.name = event.deviceName
                    item.openInMaps()
                } label: {
                    Image(systemName: "map")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 共通パーツ

private struct InfoRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
