import SwiftUI
import WebKit

/// The network map: the backend's website in embed mode, so the phone and the
/// browser show the same graph.
struct MapView: View {
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            WebPage(url: URL(string: API.base + "/?embed=1"), reload: reload)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Network")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let site = URL(string: API.base + "/") {
                            Link(destination: site) { Label("Website", systemImage: "safari") }
                        }
                    }
                }
        }
    }
}

private struct WebPage: UIViewRepresentable {
    let url: URL?
    let reload: Int

    final class Coordinator { var lastReload = -1; var lastURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard let url else { return }
        if context.coordinator.lastURL != url || context.coordinator.lastReload != reload {
            context.coordinator.lastURL = url
            context.coordinator.lastReload = reload
            v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
}
