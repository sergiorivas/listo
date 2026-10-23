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
            Button(L("task.new", "Nueva tarea")) {
                controller?.addTaskToFirstSectionAndEdit()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(controller?.mode != .app || controller?.document.sections.isEmpty != false)

            Divider()

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

            Button(L("task.split", "Dividir en tareas")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.split(taskID: id)
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.group", "Agrupar en una tarea")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.group(taskID: id)
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(controller?.mode != .app || (controller?.multiSelectedIDs.count ?? 0) < 2 || isEditingSelectedTask)

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

            Button(L("task.extendSelectionUp", "Ampliar selección hacia arriba")) {
                controller?.extendSelection(direction: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: .shift)
            .disabled(controller?.mode != .app || controller?.selectedTaskID == nil || isEditingSelectedTask)

            Button(L("task.extendSelectionDown", "Ampliar selección hacia abajo")) {
                controller?.extendSelection(direction: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: .shift)
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

/// Edit ▸ Undo / Redo (⌘Z / ⇧⌘Z), replacing the system items: those only see
/// the responder chain's `NSUndoManager`, and App Mode's changes (delete,
/// move, priority, check, ...) aren't registered with one — they live in
/// `ListoEditor`'s history.
///
/// Whoever is typing keeps their own undo: while a text field/editor is
/// first responder (a task title, the note popover) and in Free Mode, the
/// command is forwarded down the responder chain as the plain `undo:`/`redo:`
/// it would have been. Deliberately never `.disabled`: a disabled menu item
/// swallows its key equivalent, which would block that text undo whenever
/// the task history happened to be empty.
private struct UndoRedoCommands: Commands {
    @FocusedObject private var controller: DocumentController?

    private func perform(_ selector: Selector, redo: Bool = false, app: (DocumentController) -> Void) {
        // Only defer to a text view if it has something to undo/redo itself:
        // a leftover field editor with an empty history must not swallow ⌘Z
        // and leave the task history unreachable.
        let typing = (NSApp.keyWindow?.firstResponder as? NSText).map {
            redo ? ($0.undoManager?.canRedo ?? false) : ($0.undoManager?.canUndo ?? false)
        } ?? false
        if let controller, controller.mode == .app, !typing {
            app(controller)
        } else {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L("edit.undo", "Deshacer")) {
                perform(Selector(("undo:"))) { $0.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(L("edit.redo", "Rehacer")) {
                perform(Selector(("redo:")), redo: true) { $0.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

/// Decides what the app shows when nothing is open.
///
/// - Launch: the most recently opened file that still exists is opened
///   straight away; with none, the start prompt asks for an existing file or
///   a new document.
/// - Closing the last document: the start prompt again, now also listing the
///   recent files.
///
/// `DocumentGroup` creates its own blank document at launch regardless of
/// `applicationShouldOpenUntitledFile`, so `applicationDidFinishLaunching`
/// swaps a blank, unedited one for the real choice.
final class ListoAppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false
    /// True from launch until the launch routine has opened (or prompted),
    /// so closing the blank document it replaces doesn't trigger a second
    /// prompt.
    private var isLaunching = true
    private var isPrompting = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { DispatchQueue.main.async { [weak self] in self?.ensureDocumentOpen() } }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        // A beat of delay so a file double-clicked in Finder (delivered just
        // after launch) wins over the "last file" logic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.launchRoutine()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
    }

    private func launchRoutine() {
        defer { isLaunching = false }
        let docs = NSDocumentController.shared.documents
        // Something real is already open (Finder double-click, restored
        // window): leave it. Never close a document the user typed into.
        guard docs.allSatisfy({ $0.fileURL == nil && !$0.isDocumentEdited }) else { return }
        docs.forEach { $0.close() }
        if let last = existingRecents().first {
            open(last)
        } else {
            showStartPrompt(recents: [])
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Deferred a runloop turn: the closing document is still registered
        // with `NSDocumentController` while `willClose` fires.
        DispatchQueue.main.async { [weak self] in self?.ensureDocumentOpen() }
    }

    private func ensureDocumentOpen() {
        guard !isTerminating, !isLaunching, !isPrompting,
              NSDocumentController.shared.documents.isEmpty else { return }
        showStartPrompt(recents: existingRecents())
    }

    private func existingRecents() -> [URL] {
        RecentFilesStore.shared.recentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] document, _, _ in
            if document == nil, NSDocumentController.shared.documents.isEmpty {
                self?.showStartPrompt(recents: self?.existingRecents() ?? [])
            }
        }
    }

    /// Existing file / recent file / new document, or quit. Looping on a
    /// cancelled open panel so the user is never left with an empty app.
    private func showStartPrompt(recents: [URL]) {
        guard !isPrompting else { return }
        isPrompting = true
        defer { isPrompting = false }

        let alert = NSAlert()
        alert.messageText = L("start.title", "Elegí una lista")
        alert.informativeText = recents.isEmpty
            ? L("start.message.noRecents", "Abrí un archivo de tareas existente o creá un documento nuevo.")
            : L("start.message.recents", "Abrí un archivo reciente, buscá uno existente o creá un documento nuevo.")

        var popup: NSPopUpButton?
        if !recents.isEmpty {
            let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            for url in recents {
                button.addItem(withTitle: url.lastPathComponent)
                button.lastItem?.toolTip = url.path
            }
            alert.accessoryView = button
            popup = button
            alert.addButton(withTitle: L("start.openRecent", "Abrir reciente"))
        }
        alert.addButton(withTitle: L("start.openFile", "Abrir archivo…"))
        alert.addButton(withTitle: L("start.new", "Nuevo documento"))
        alert.addButton(withTitle: L("start.quit", "Salir"))

        NSApp.activate(ignoringOtherApps: true)
        var response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if popup == nil { response += 1 } // no "Abrir reciente" button
        switch response {
        case 0:
            if let index = popup?.indexOfSelectedItem, recents.indices.contains(index) {
                open(recents[index])
            }
        case 1:
            NSDocumentController.shared.beginOpenPanel { [weak self] urls in
                guard let self else { return }
                guard let urls, !urls.isEmpty else {
                    DispatchQueue.main.async { self.ensureDocumentOpen() }
                    return
                }
                urls.forEach { self.open($0) }
            }
        case 2:
            NSDocumentController.shared.newDocument(nil)
        default:
            NSApp.terminate(nil)
        }
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
                .keyboardShortcut("n", modifiers: [.command, .shift])

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
            UndoRedoCommands()
            TaskCommands()
        }

        Settings {
            SettingsView()
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.theme.colorScheme)
        }
    }
}
