import SwiftUI
import AppKit

/// The document window's frame, remembered across launches: a window opens
/// at the size (and place) the last one had when it was resized, moved or
/// closed. One frame for the app, not one per file, so a new list opens
/// like the last one did too.
///
/// Not `NSWindow.setFrameAutosaveName`: autosave names must be unique per
/// window, so with two documents open only one would get it, and
/// `DocumentGroup` sizes its windows from the SwiftUI ideal size after
/// AppKit would have applied the autosaved frame.
enum WindowFrameStore {
    static let key = "listo.window.frame"

    static func load(from defaults: UserDefaults = .standard) -> NSRect? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    static func save(_ frame: NSRect, to defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: key)
    }

    /// Where a saved frame should go given the screens available now. Kept
    /// as is when it still sits on a screen; otherwise (a monitor that was
    /// unplugged) the size is kept, shrunk to fit, and centred on the main
    /// screen. `nil` when there is no screen at all.
    static func placement(of saved: NSRect, screens: [NSRect]) -> NSRect? {
        guard let main = screens.first else { return nil }
        let onScreen = screens.contains { screen in
            let overlap = screen.intersection(saved)
            // A sliver isn't enough to grab the title bar back.
            return overlap.width >= 100 && overlap.height >= 50
        }
        if onScreen { return saved }
        let size = NSSize(width: min(saved.width, main.width), height: min(saved.height, main.height))
        return NSRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Attach with `.background(WindowFrameKeeper())`: restores the stored
/// frame once when the view lands in its window, then records every resize
/// and move. Restoring waits a runloop turn, because SwiftUI applies the
/// content's ideal size after the view is installed and would otherwise
/// win; saving only starts after that, so the initial size can't overwrite
/// the stored one first.
struct WindowFrameKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeeperView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class KeeperView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var restored = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !restored, let window else { return }
            restored = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let saved = WindowFrameStore.load(),
                       let frame = WindowFrameStore.placement(
                           of: saved, screens: NSScreen.screens.map(\.visibleFrame)) {
                        window.setFrame(frame, display: true)
                    }
                    self?.observe(window)
                }
            }
        }

        private func observe(_ window: NSWindow) {
            let names: [Notification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.willCloseNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        // A full-screen frame isn't one to reopen at; keep
                        // the last windowed one.
                        guard !window.styleMask.contains(.fullScreen) else { return }
                        WindowFrameStore.save(window.frame)
                    }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
