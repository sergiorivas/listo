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
    private let hotKeyID: UInt32
    private static var nextID: UInt32 = 1

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        hotKeyID = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Every instance's handler sees every hot key the app registered, so
        // each one only acts on its own id and passes the rest along.
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == GlobalHotKey.signature,
                  pressed.id == hotKey.hotKeyID else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    private static let signature = OSType(0x4C53_544F) // "LSTO"

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// The menu bar icon plus two system-wide keys, all on the first column of
/// the frontmost open document, without bringing its window forward:
/// ⌃⌥⌘T a field to add a task, ⌃⌥⌘N a glance at its top 3 tasks, and the
/// menu bar icon both at once.
///
/// A non-activating `NSPanel` rather than an `NSPopover`: a popover can only
/// take typing if the app is activated, which would raise every Listo
/// window over whatever the user was doing. The panel takes key focus while
/// Listo stays in the background, like Spotlight.
@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    static let shared = QuickAddController()

    private var statusItem: NSStatusItem?
    private var hotKeys: [GlobalHotKey] = []
    private var panel: QuickAddPanel?
    private var shownMode: QuickAddMode?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Listo")
        item.button?.toolTip = L("quickAdd.tooltip", "Agregar tarea (⌃⌥⌘T)")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item

        let modifiers = controlKey | optionKey | cmdKey
        hotKeys = [
            GlobalHotKey(keyCode: kVK_ANSI_T, modifiers: modifiers) { [weak self] in self?.toggle(.add) },
            GlobalHotKey(keyCode: kVK_ANSI_N, modifiers: modifiers) { [weak self] in self?.toggle(.preview) },
        ].compactMap { $0 }
    }

    @objc private func statusItemClicked() { toggle(.addWithPreview) }

    /// The same key again closes the panel; another one swaps its content.
    func toggle(_ mode: QuickAddMode) {
        if let panel, panel.isVisible, shownMode == mode {
            close()
        } else {
            show(mode)
        }
    }

    private func show(_ mode: QuickAddMode) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        shownMode = mode
        // A fresh root view each time: empty field, focus claimed in
        // `onAppear`, target document looked up anew.
        let host = NSHostingView(rootView: QuickAddView(
            target: Self.targetController(),
            mode: mode,
            onDone: { [weak self] in self?.close() }
        ))
        // The panel isn't one of the SwiftUI scenes `preferredColorScheme`
        // reaches, so it takes Settings ▸ Theme directly (nil = follow macOS).
        panel.appearance = AppSettings.shared.theme.nsAppearance
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        shownMode = nil
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

enum QuickAddMode {
    case add, preview, addWithPreview
    var showsField: Bool { self != .preview }
    var showsPreview: Bool { self != .add }
}

private struct QuickAddView: View {
    let target: DocumentController?
    let mode: QuickAddMode
    let onDone: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode.showsField {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(problem == nil ? Color.accentColor : .secondary)
                        .font(settings.font(.title3))
                    TextField(L("quickAdd.placeholder", "Nueva tarea"), text: $text)
                        .textFieldStyle(.plain)
                        .font(settings.font(.title3))
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit(add)
                        .disabled(problem != nil)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(settings.font(.caption))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } else if let target, let section = target.document.sections.first {
                if mode.showsPreview {
                    QuickAddPreview(controller: target, section: section, documentName: documentName)
                } else {
                    Text("\(documentName) › \(section.title)")
                        .font(settings.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 2)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .onExitCommand(perform: onDone)
        .onAppear { if mode.showsField { DispatchQueue.main.async { focused = true } } }
    }

    /// Why the panel can't be used right now, if it can't.
    private var problem: String? {
        guard let target else { return L("quickAdd.noDocument", "No hay ninguna lista abierta") }
        if target.mode != .app { return L("quickAdd.freeMode", "Salí del Modo Libre para agregar tareas") }
        if target.document.sections.isEmpty { return L("quickAdd.noSections", "La lista no tiene columnas") }
        return nil
    }

    private var documentName: String {
        target?.fileURL?.deletingPathExtension().lastPathComponent ?? L("quickAdd.untitled", "Sin título")
    }

    private func add() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard problem == nil, !title.isEmpty, let target, let section = target.document.sections.first else { return }
        target.addTask(text: title, toSectionID: section.id)
        onDone()
    }
}

/// The first few tasks of the target column, in the order the board shows
/// them (priority first), drawn with the board's own pieces (checkbox,
/// priority, due/tag badges, count badge, first-column tint) so it reads as
/// a slice of the column. Display only: nothing in it is clickable.
private struct QuickAddPreview: View {
    static let limit = 3
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let section: ListoSection
    let documentName: String

    var body: some View {
        let tasks = section.displayTasks
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(settings.font(.headline, weight: .semibold))
                    .lineLimit(1)
                SectionCountBadge(count: section.taskCount)
                Spacer(minLength: 8)
                Text(documentName)
                    .font(settings.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if tasks.isEmpty {
                Text(L("quickAdd.emptyColumn", "Todavía no hay tareas"))
                    .font(settings.font(.body))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tasks.prefix(Self.limit)) { task in
                        row(task)
                    }
                }
                if tasks.count > Self.limit {
                    Text(String(format: L("quickAdd.more", "y %d más"), tasks.count - Self.limit))
                        .font(settings.font(.caption))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(columnTint))
        .allowsHitTesting(false)
    }

    private func row(_ task: ListoTask) -> some View {
        let done = task.state == .done
        return HStack(spacing: 6) {
            TaskCheckboxIcon(isDone: done)
                .font(settings.font(.body))
            Text(task.displayTitle.isEmpty ? task.text : task.displayTitle)
                .font(settings.font(.body))
                .strikethrough(done)
                .foregroundStyle(done ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            PriorityBadge(priority: task.priority, dimmed: done)
            TaskMetaBadges(controller: controller, task: task)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    /// The board's first-column colour when that setting is on, else a
    /// neutral fill that works on both themes.
    private var columnTint: Color {
        settings.firstSectionBackgroundEnabled
            ? settings.firstSectionBackgroundColor.opacity(0.18)
            : Color.primary.opacity(0.04)
    }
}
