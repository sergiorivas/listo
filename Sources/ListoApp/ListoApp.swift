import SwiftUI
import AppKit
import ListoEngine

/// Indent/outdent-selected-task and clear-selection, as real menu bar
/// commands rather than a view-level key handler.
///
/// A row's own `.onKeyPress` only fires while that exact row holds real
/// AppKit keyboard focus — and a `@FocusState` flip from inside a tap
/// gesture handler (how a row becomes "selected") doesn't reliably acquire
/// that focus on macOS, so a merely-selected (not text-editing) row's
/// Escape could silently do nothing. Menu key equivalents don't have that
/// requirement: they're resolved against the frontmost window regardless of
/// which specific subview has focus — the same mechanism already relied on
/// for the Font Size shortcuts below, just scoped here to whichever
/// document window is currently focused.
///
/// Indent/Outdent use ⌘]/⌘[, not Tab/⇧Tab, *here* — confirmed directly:
/// bare Tab/⇧Tab key equivalents on a custom `NSMenuItem` never fire at all
/// while merely selected (clicking the menu item itself works fine; the
/// key equivalent just never reaches it), because macOS reserves both for
/// moving keyboard focus between controls and claims them before
/// `performKeyEquivalent` ever sees them. That reservation doesn't apply
/// once a row *is* a live text field — Tab/⇧Tab there are the field's own
/// `onKeyPress` (`OutlineBoardView`/`KanbanView`), a completely different,
/// working path — so this only affects the selected-but-not-editing case.
///
/// `@FocusedObject`, not `@FocusedValue`: `DocumentController` is an
/// `ObservableObject`, and `@FocusedValue` only re-evaluates `body` when the
/// exposed *reference itself* is reassigned (e.g. a different window gains
/// focus) — it does not subscribe to that object's own `@Published`
/// changes. With `@FocusedValue` here, every `.disabled(...)` below got
/// permanently stuck at whatever `selectedTaskID`/`editingTaskID` happened
/// to be at the *first* time this menu was built (nil, nil — so
/// permanently disabled), never updating as the user clicked around,
/// regardless of the actual selection state (confirmed directly: clicking
/// a task's checkbox visibly toggled it — proving `selectedTaskID` really
/// was being set — while the menu stayed disabled). `@FocusedObject` is the
/// variant built for exactly this: it re-invokes `body` on the object's own
/// `objectWillChange`, matched here by `ContentView`'s
/// `.focusedSceneObject(controller)` (not `.focusedSceneValue`).
private struct TaskCommands: Commands {
    @FocusedObject private var controller: DocumentController?

    /// While a task's title is a live text field, that field's own
    /// `onKeyPress` owns Tab/⇧Tab/Return for it directly — and, it turns
    /// out, owning them does *not* stop these app-level shortcuts from also
    /// firing for the very same keystroke (observed directly: Tab while
    /// editing indented the task *and* left the original row in place, a
    /// silent double `indentTask` — one from the field, one from here).
    ///
    /// Scoped to "the row this menu command would act on (`selectedTaskID`)
    /// is the row currently in the text field" — not just "*some* task is
    /// being edited" — on purpose: `editingTaskID` clearing depends on
    /// `@FocusState` correctly noticing the field lost focus, which (same
    /// class of flakiness noted elsewhere in this file) doesn't always
    /// fire, e.g. when focus moves because the user clicked a *different*
    /// row rather than pressing Return/Escape. A global "is anything being
    /// edited" check would then wedge these commands off for every row,
    /// forever, the moment that happened once. Comparing against
    /// `selectedTaskID` self-heals: clicking a different row changes
    /// `selectedTaskID` immediately, which re-enables these regardless of
    /// whether the stale `editingTaskID` ever got cleared.
    private var isEditingSelectedTask: Bool {
        controller?.editingTaskID != nil && controller?.editingTaskID == controller?.selectedTaskID
    }

    var body: some Commands {
        CommandMenu(L("menu.task", "Tarea")) {
            Button(L("task.indent", "Indentar")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.indent(taskID: id)
                }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.outdent", "Quitar indentación")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.outdent(taskID: id)
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.delete", "Eliminar")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.delete(taskID: id)
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.moveUp", "Mover arriba")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.reorder(taskID: id, direction: -1)
                }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.moveDown", "Mover abajo")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.reorder(taskID: id, direction: 1)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            // Kanban only: columns are what "previous/next section" means
            // there. Also disabled while editing, where ⌘←/⌘→ are the text
            // field's own "jump to start/end of line".
            Button(L("task.moveToPreviousSection", "Mover a la sección anterior")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.moveToAdjacentSection(taskID: id, direction: -1)
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(controller?.mode != .app || controller?.viewStyle != .kanban
                      || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.moveToNextSection", "Mover a la sección siguiente")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.moveToAdjacentSection(taskID: id, direction: 1)
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(controller?.mode != .app || controller?.viewStyle != .kanban
                      || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Divider()

            Button(L("task.previous", "Tarea anterior")) {
                controller?.selectAdjacent(direction: -1, keepEditing: false)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.next", "Tarea siguiente")) {
                controller?.selectAdjacent(direction: 1, keepEditing: false)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Divider()

            Button(L("selection.clear", "Deseleccionar")) {
                controller?.selectedTaskID = nil
            }
            .keyboardShortcut(.cancelAction)
            .disabled(controller?.selectedTaskID == nil)
        }
    }
}

/// Reopens the last document on launch instead of a blank "untitled" list,
/// and backs the app's own "Abrir reciente" menu.
///
/// Belt and suspenders: `applicationShouldOpenUntitledFile` is the
/// documented hook for this, but SwiftUI's `DocumentGroup` doesn't always
/// consistently route through it before creating its own blank document —
/// so `applicationDidFinishLaunching` also checks, shortly after launch,
/// whether the only window open is an untitled/unedited one and swaps it
/// for the real file if so. Either path is a no-op once the last file is
/// already open.
final class ListoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !openLastFileIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.openLastFileIfNeeded()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    // MARK: Always keep one file open

    private var isTerminating = false

    /// Closing the last document window would leave the app running with
    /// nothing open, so open another file in its place: the most recent one
    /// that still exists (preferring one other than the file just closed, so
    /// closing doesn't just bounce the same file straight back), or a blank
    /// list if there are none. Deferred a runloop turn because the closing
    /// document is still registered with `NSDocumentController` while
    /// `willClose` fires. Quitting is exempt.
    @objc private func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        let closed = (window?.windowController?.document as? NSDocument)?.fileURL
        DispatchQueue.main.async { [weak self] in
            self?.ensureDocumentOpen(closed: closed)
        }
    }

    private func ensureDocumentOpen(closed: URL?) {
        guard !isTerminating, NSDocumentController.shared.documents.isEmpty else { return }
        let existing = RecentFilesStore.shared.recentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let target = existing.first(where: { $0 != closed }) ?? existing.first else {
            NSDocumentController.shared.newDocument(nil)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { document, _, _ in
            if document == nil, NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }

    @discardableResult
    private func openLastFileIfNeeded() -> Bool {
        guard let last = RecentFilesStore.shared.lastOpenedURL,
              FileManager.default.fileExists(atPath: last.path) else {
            return false
        }
        let docs = NSDocumentController.shared.documents
        guard !docs.contains(where: { $0.fileURL == last }) else {
            return true // already open
        }
        // Only safe to replace documents that are blank/untitled and have
        // no unsaved work — never close something the user actually typed.
        guard docs.allSatisfy({ $0.fileURL == nil && !$0.isDocumentEdited }) else {
            return false
        }
        docs.forEach { $0.close() }
        NSDocumentController.shared.openDocument(withContentsOf: last, display: true) { _, _, _ in }
        return true
    }
}

@main
struct ListoApp: App {
    @NSApplicationDelegateAdaptor(ListoAppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recents = RecentFilesStore.shared

    var body: some Scene {
        DocumentGroup(newDocument: { ListoFileDocument() }) { file in
            ContentView(fileDocument: file.document, fileURL: file.fileURL)
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button {
                    NSDocumentController.shared.newDocument(nil)
                } label: {
                    Label(L("menu.newList", "Nueva lista"), systemImage: "doc.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu {
                    if recents.recentURLs.isEmpty {
                        Text(L("menu.recent.empty", "Sin archivos recientes"))
                    } else {
                        ForEach(recents.recentURLs, id: \.self) { url in
                            Button {
                                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                            } label: {
                                Label(url.lastPathComponent, systemImage: "doc.text")
                            }
                        }
                        Divider()
                        Button(L("menu.recent.clear", "Borrar recientes")) {
                            recents.clear()
                        }
                    }
                } label: {
                    Label(L("menu.recent", "Abrir reciente"), systemImage: "clock")
                }
            }
            CommandMenu(L("menu.view", "Ver")) {
                Button {
                    settings.increaseFontSize()
                } label: {
                    Label(L("zoom.in", "Aumentar tamaño de fuente"), systemImage: "textformat.size.larger")
                }
                .keyboardShortcut("=", modifiers: .command)

                Button {
                    settings.decreaseFontSize()
                } label: {
                    Label(L("zoom.out", "Reducir tamaño de fuente"), systemImage: "textformat.size.smaller")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    settings.resetFontSize()
                } label: {
                    Label(L("zoom.reset", "Restablecer tamaño de fuente"), systemImage: "textformat.size")
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            TaskCommands()
        }

        Settings {
            SettingsView()
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
