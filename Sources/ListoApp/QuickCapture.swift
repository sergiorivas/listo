import SwiftUI
import AppKit
import Carbon.HIToolbox
import ListoEngine

/// Adds a task to a list without going to its window: from the global
/// shortcut's floating box (`QuickCapturePanel`) or the optional menu-bar
/// box. The task lands at the end of the list's first section — its inbox.
@MainActor
enum QuickCapture {
    enum Failure: LocalizedError {
        case noList

        var errorDescription: String? {
            L("capture.noList", "Abrí una lista primero, o elegí una en Ajustes ▸ Captura rápida.")
        }
    }

    /// The list chosen in Settings, else the most recently opened one.
    static var targetURL: URL? {
        if let path = AppSettings.shared.quickCapturePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return RecentFilesStore.shared.lastOpenedURL
    }

    /// `Launch.md › To Do` — where the next capture goes.
    static var destinationLabel: String? {
        guard let url = targetURL else { return nil }
        let sections = openController(for: url)?.document.sections
            ?? (try? String(contentsOf: url, encoding: .utf8)).map { ListoParser.parse($0).sections }
            ?? []
        return url.lastPathComponent + " › " + (sections.first?.title ?? inboxTitle)
    }

    /// The section created when the list has none yet.
    static var inboxTitle: String { L("capture.inboxSection", "Bandeja de entrada") }

    /// Adds `text` (typed dates like `@tomorrow` resolved, as anywhere else)
    /// to the target list's first section. When the list is open in a
    /// window, that window's controller does it, so its board, undo history
    /// and saving stay in charge; otherwise the file is edited directly.
    static func add(_ text: String) throws {
        guard let url = targetURL else { throw Failure.noList }
        if let controller = openController(for: url) {
            try controller.capture(text)
            return
        }
        let editor = try ListoEditor(fileURL: url)
        if editor.document.sections.isEmpty {
            try editor.addSection(title: inboxTitle)
        }
        try editor.addTask(text: text, toSectionID: editor.document.sections[0].id)
    }

    private static func openController(for url: URL) -> DocumentController? {
        DocumentController.live.allObjects.first {
            $0.fileURL?.standardizedFileURL == url.standardizedFileURL
        }
    }
}

extension DocumentController {
    /// A quick-capture task for this window's list (see `QuickCapture`).
    func capture(_ text: String) throws {
        if mode == .freeEdit {
            // Free Mode's text is what the user is editing: add the line to
            // it, to be interpreted (and logged) on the next save like any
            // edit there. A scratch editor works out where the line goes
            // without writing anything next to the real file.
            let scratchURL = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).md")
            let scratch = ListoEditor(fileURL: scratchURL, initialText: fileDocument.text, autoPersist: false)
            defer { try? FileManager.default.removeItem(at: scratch.logWriter.logFileURL) }
            if scratch.document.sections.isEmpty {
                try scratch.addSection(title: QuickCapture.inboxTitle)
            }
            try scratch.addTask(text: text, toSectionID: scratch.document.sections[0].id)
            fileDocument.text = scratch.currentText
            return
        }
        if document.sections.isEmpty {
            perform { try $0.addSection(title: QuickCapture.inboxTitle) }
        }
        guard let first = document.sections.first else { return }
        revealOutlineSection(first.id)
        guard perform(animation: Motion.snappy, { try $0.addTask(text: text, toSectionID: first.id) }) else {
            throw CaptureError(message: errorMessage ?? "")
        }
        // The capture box, not this window, is key: make sure the save
        // reaches this document rather than relying on the responder chain.
        if let fileURL { NSDocumentController.shared.document(for: fileURL)?.save(nil) }
    }

    private struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// The capture box itself, shared by the floating panel and the menu-bar
/// window.
struct QuickCaptureView: View {
    /// The floating panel closes after one task; the menu-bar box stays
    /// open for the next one.
    let closesAfterAdding: Bool
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""
    @State private var status: String?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("capture.placeholder", "Nueva tarea — probá @mañana, #etiqueta, !!"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                Text(status ?? QuickCapture.destinationLabel ?? L("capture.noTarget", "Ninguna lista elegida"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(failed ? Color.red : Color.secondary)
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
        .id(settings.reloadToken)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try QuickCapture.add(trimmed)
            text = ""
            failed = false
            if closesAfterAdding {
                onClose()
            } else {
                status = String(format: L("capture.added", "Agregada a %@"), QuickCapture.destinationLabel ?? "")
            }
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }
}

/// The floating capture box the global shortcut opens. Non-activating, so
/// typing into it doesn't bring Listo's windows to the front, and it goes
/// away as soon as it loses focus.
@MainActor
final class QuickCapturePanel {
    static let shared = QuickCapturePanel()

    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?

    /// Registers or drops the global shortcut to match Settings.
    func syncHotKey() {
        if AppSettings.shared.quickCaptureHotKeyEnabled {
            guard hotKey == nil else { return }
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey)) {
                DispatchQueue.main.async { QuickCapturePanel.shared.toggle() }
            }
        } else {
            hotKey = nil
        }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh view each time: an empty field, no leftover status.
        panel.contentView = NSHostingView(rootView: QuickCaptureView(closesAfterAdding: true) { [weak self] in
            self?.close()
        })
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 440, height: 70))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + frame.height * 0.7
            ))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 70),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            panel.orderOut(nil)
        }
        return panel
    }
}

/// A panel that can take keyboard focus without activating the app.
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A system-wide keyboard shortcut (Carbon's `RegisterEventHotKey`, which
/// needs no Accessibility permission). Unregistered when released.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        // 'LSTO'
        let id = EventHotKeyID(signature: OSType(0x4C53_544F), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
