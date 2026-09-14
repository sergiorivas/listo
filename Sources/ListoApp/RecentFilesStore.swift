import Foundation

/// Tracks recently opened documents so the app can reopen the last one at
/// launch and offer its own "Abrir reciente" menu — on top of (not instead
/// of) the automatic File > Open Recent that AppKit's NSDocumentController
/// already gives a DocumentGroup app for free.
final class RecentFilesStore: ObservableObject {
    static let shared = RecentFilesStore()

    @Published private(set) var recentURLs: [URL] = []
    var lastOpenedURL: URL? { recentURLs.first }

    private let maxCount = 10
    private let key = "listo.settings.recentFiles"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        recentURLs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func recordOpened(_ url: URL) {
        guard url.isFileURL else { return }
        // No-op if it's already the most recent entry: this is called from
        // ContentView.init/.onChange, which SwiftUI re-runs on every
        // reconstruction — since ListoApp itself observes `recentURLs` (for
        // the "Abrir reciente" menu), an unconditional publish here would
        // feed back into a re-render that reconstructs ContentView again,
        // looping forever (this previously hung the app when opening or
        // saving a file).
        guard recentURLs.first != url else { return }
        var urls = recentURLs.filter { $0 != url }
        urls.insert(url, at: 0)
        if urls.count > maxCount {
            urls.removeLast(urls.count - maxCount)
        }
        recentURLs = urls
        persist()
    }

    func remove(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        persist()
    }

    func clear() {
        recentURLs = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: key)
    }
}
