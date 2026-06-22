import SwiftUI
import WebKit
import CoreLocation

/// アプリ内に Google マップを埋め込むビュー。
///
/// Google Maps SDK（APIキー必須）ではなく、APIキー不要の埋め込みURL
/// （`...&output=embed`）を `WKWebView` で読み込むことで、アプリ内に
/// 操作可能な Google マップを表示する。マーカーは `q=緯度,経度` の位置に立つ。
struct GoogleMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    /// ズームレベル（大きいほど拡大）。
    var zoom: Int = 17

    private var embedURL: URL? {
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        return URL(string: "https://www.google.com/maps?q=\(lat),\(lng)&z=\(zoom)&hl=ja&output=embed")
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url = embedURL else { return }
        // 同じURLを再読み込みしないよう、現在のURLと違うときだけ読み込む。
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }
}

/// Google マップを全画面（シート）で表示する画面。
struct GoogleMapScreen: View {
    let event: DisconnectEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GoogleMapView(coordinate: event.coordinate)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(event.deviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
