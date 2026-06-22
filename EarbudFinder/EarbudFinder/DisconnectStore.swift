import Foundation
import Combine

/// 切断イベントの永続化と読み込みを担当するストア。
/// ドキュメントディレクトリのJSONファイルに保存する。
@MainActor
final class DisconnectStore: ObservableObject {
    @Published private(set) var events: [DisconnectEvent] = []

    private let fileURL: URL

    init(fileName: String = "disconnects.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent(fileName)
        load()
    }

    /// 最新（直近）の切断イベント。
    var latest: DisconnectEvent? { events.first }

    /// 日付（その日の0時）ごとにまとめた切断イベント。新しい日が先頭。
    /// 各日の中も新しい順。日付ごとに見返せるUI用。
    var eventsByDay: [(day: Date, events: [DisconnectEvent])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return groups
            .map { (day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    func add(_ event: DisconnectEvent) {
        events.insert(event, at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        events.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([DisconnectEvent].self, from: data) {
            events = decoded.sorted { $0.date > $1.date }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
