import SwiftUI
import AppKit
import ListoEngine

/// Exposes the frontmost window's `DocumentController` to app-level
/// `.commands` (`TaskCommands` below), via `ContentView`'s
/// `.focusedSceneValue(\.listoController, controller)`.
private struct ListoControllerFocusedValueKey: FocusedValueKey {
    typealias Value = DocumentController
}

extension FocusedValues {
    var listoController: DocumentController? {
        get { self[ListoControllerFocusedValueKey.self] }
        set { self[ListoControllerFocusedValueKey.self] = newValue }
    }
}

/// Indent/outdent-selected-task and clear-selection, as real menu bar
/// commands rather than a view-level key handler.
///
/// A row's own `.onKeyPress` only fires while that exact row holds real
/// AppKit keyboard focus — and a `@FocusState` flip from inside a tap
/// gesture handler (how a row becomes "selected") doesn't reliably acquire
/// that focus on macOS, so a merely-selected (not text-editing) row's
/// Tab/⇧Tab/Escape could silently do nothing. Menu key equivalents don't
/// have that requirement: they're resolved against the frontmost window
/// regardless of which specific subview has focus — the same mechanism
/// already relied on for the Font Size shortcuts below, just scoped here to
/// whichever document window is currently focused via `@FocusedValue`.
private struct TaskCommands: Commands {
    @FocusedValue(\.listoController) private var controller

    var body: some Commands {
        CommandMenu(L("menu.task", "Tarea")) {
            Button(L("task.indent", "Indentar")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.indent(taskID: id)
                }
            }
            .keyboardShortcut(.tab, modifiers: [])
            .disabled(controller?.selectedTaskID == nil)

            Button(L("task.outdent", "Quitar indentación")) {
                if let controller, let id = controller.selectedTaskID {
                    controller.outdent(taskID: id)
                }
            }
            .keyboardShortcut(.tab, modifiers: [.shift])
            .disabled(controller?.selectedTaskID == nil)

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
