import SwiftUI
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
    @State private var showFullMap = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("最後に切れた場所", systemImage: "mappin.and.ellipse")
                    .font(.headline)

                if event.hasValidLocation {
                    // アプリ内の Google マップ。
                    GoogleMapView(coordinate: event.coordinate)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    InfoRow(icon: "clock", text: event.date.formatted(date: .abbreviated, time: .shortened))
                    if let distance = distanceText {
                        InfoRow(icon: "figure.walk", text: "現在地からおよそ \(distance)")
                    }
                    InfoRow(icon: "scope", text: "精度 約\(Int(event.horizontalAccuracy))m")

                    Button {
                        showFullMap = true
                    } label: {
                        Label("大きな地図で見る", systemImage: "map.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .sheet(isPresented: $showFullMap) {
                        GoogleMapScreen(event: event)
                    }
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("履歴")
                        .font(.headline)
                    Spacer()
                    Button("すべて消去", role: .destructive) {
                        model.store.clear()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 4)

                // 日付ごとにまとめて表示。
                ForEach(model.store.eventsByDay, id: \.day) { group in
                    DaySection(day: group.day, events: group.events)
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

/// 1日分の切断イベントをまとめたセクション。
private struct DaySection: View {
    let day: Date
    let events: [DisconnectEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        HistoryRow(event: event)
                        if event.id != events.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// 「今日」「昨日」または日付（曜日つき）。
    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今日" }
        if calendar.isDateInYesterday(day) { return "昨日" }
        return day.formatted(.dateTime.year().month().day().weekday(.abbreviated))
    }
}

private struct HistoryRow: View {
    let event: DisconnectEvent
    @State private var showFullMap = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.hasValidLocation ? "mappin.circle.fill" : "mappin.slash.circle")
                .foregroundStyle(event.hasValidLocation ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.deviceName)
                    .font(.subheadline.weight(.medium))
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if event.hasValidLocation {
                    Text(String(format: "%.5f, %.5f", event.latitude, event.longitude))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if event.hasValidLocation {
                Button {
                    showFullMap = true
                } label: {
                    Image(systemName: "map.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if event.hasValidLocation { showFullMap = true }
        }
        .sheet(isPresented: $showFullMap) {
            GoogleMapScreen(event: event)
        }
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
