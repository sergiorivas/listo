import SwiftUI
import AppKit
import Carbon.HIToolbox
import ListoEngine

/// A system-wide hot key through Carbon's `RegisterEventHotKey`: unlike an
/// `NSEvent` global monitor it needs no Accessibility permission, and it
/// swallows the keystroke instead of also passing it to the frontmost app.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4C53_544F), id: 1) // "LSTO"
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// The menu bar icon plus ⌃⌥⌘T: a small floating field that adds a task to
/// the first column of the frontmost open document without bringing its
/// window forward.
///
/// A non-activating `NSPanel` rather than an `NSPopover`: a popover can only
/// take typing if the app is activated, which would raise every Listo
/// window over whatever the user was doing. The panel takes key focus while
/// Listo stays in the background, like Spotlight.
@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    static let shared = QuickAddController()

    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var panel: QuickAddPanel?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Listo")
        item.button?.toolTip = L("quickAdd.tooltip", "Agregar tarea (⌃⌥⌘T)")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item

        hotKey = GlobalHotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggle()
        }
    }

    @objc private func statusItemClicked() { toggle() }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh root view each time: empty field, focus claimed in
        // `onAppear`, target document looked up anew.
        let host = NSHostingView(rootView: QuickAddView(
            target: Self.targetController(),
            onDone: { [weak self] in self?.close() }
        ))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> QuickAddPanel {
        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    /// Under the status item when it's on screen (it can be hidden by a
    /// crowded menu bar or a notch), else top-centre of the main screen.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let button = statusItem?.button, let window = button.window,
           window.frame.width > 0, let screen = window.screen {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - size.width / 2
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 80))
        }
    }

    /// Clicking anywhere else dismisses it, like a popover.
    func windowDidResignKey(_ notification: Notification) { close() }

    /// The document whose window is frontmost in Listo's own window order
    /// (it doesn't need to be active), else any open one.
    static func targetController() -> DocumentController? {
        let live = DocumentController.live.allObjects
        for window in NSApp.orderedWindows {
            guard let url = (window.windowController?.document as? NSDocument)?.fileURL else { continue }
            if let match = live.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                return match
            }
        }
        return live.first
    }
}

private final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private struct QuickAddView: View {
    let target: DocumentController?
    let onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                TextField(L("quickAdd.placeholder", "Nueva tarea"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit(add)
                    .disabled(problem != nil)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(problem == nil ? .secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .onExitCommand(perform: onDone)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// Why the field can't be used right now, if it can't.
    private var problem: String? {
        guard let target else { return L("quickAdd.noDocument", "No hay ninguna lista abierta") }
        if target.mode != .app { return L("quickAdd.freeMode", "Salí del Modo Libre para agregar tareas") }
        if target.document.sections.isEmpty { return L("quickAdd.noSections", "La lista no tiene columnas") }
        return nil
    }

    private var caption: String {
        if let problem { return problem }
        guard let target, let section = target.document.sections.first else { return "" }
        let name = target.fileURL?.deletingPathExtension().lastPathComponent ?? L("quickAdd.untitled", "Sin título")
        return "\(name) › \(section.title)"
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard problem == nil, !title.isEmpty, let target, let section = target.document.sections.first else { return }
        target.addTask(text: title, toSectionID: section.id)
        onDone()
    }
}
