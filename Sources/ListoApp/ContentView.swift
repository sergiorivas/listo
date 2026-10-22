import SwiftUI
import AppKit
import ListoEngine

struct ContentView: View {
    @ObservedObject var fileDocument: ListoFileDocument
    let fileURL: URL?
    @StateObject private var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @State private var showLog = false

    init(fileDocument: ListoFileDocument, fileURL: URL?) {
        self.fileDocument = fileDocument
        self.fileURL = fileURL
        _controller = StateObject(wrappedValue: DocumentController(fileDocument: fileDocument, fileURL: fileURL))
    }

    var body: some View {
        Group {
            switch controller.mode {
            case .app:
                switch controller.viewStyle {
                case .kanban:
                    KanbanView(controller: controller)
                case .outline:
                    OutlineBoardView(controller: controller)
                }
            case .freeEdit:
                FreeEditView(text: $fileDocument.text)
            }
        }
        .frame(minWidth: 480, idealWidth: idealWindowWidth, minHeight: 360, idealHeight: 640)
        // Exposes this window's controller to the app-level Task menu
        // (ListoApp.swift's `TaskCommands`), which is what actually owns
        // the Tab/⇧Tab/Delete keyboard shortcuts — see that file for why
        // menu-bar commands, not a hidden in-view button, are what reliably
        // catches these regardless of which row (if any) has real keyboard
        // focus, and why this is `focusedSceneObject`, not
        // `focusedSceneValue`: the menu needs to react to this object's own
        // `@Published` changes (selection/edit state), not just to *which*
        // controller is focused.
        .focusedSceneObject(controller)
        .safeAreaInset(edge: .top, spacing: 0) {
            if controller.mode == .app { FilterBar(controller: controller) }
        }
        .toolbar {
            // Grouped by purpose, with spacing between groups: what the
            // document is shown as (left), how it is narrowed, and history.
            ToolbarItemGroup(placement: .navigation) {
                Picker(L("picker.mode", "Modo"), selection: $controller.mode) {
                    Text(L("mode.app", "App")).tag(EditMode.app)
                    Text(L("mode.free", "Libre")).tag(EditMode.freeEdit)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help(L("picker.mode.help", "Cambiar entre Modo App y Modo Libre"))

                if controller.mode == .app {
                    Picker(L("picker.view", "Vista"), selection: $controller.viewStyle) {
                        Label(L("view.kanban", "Kanban"), systemImage: "rectangle.split.3x1").tag(ViewStyle.kanban)
                        Label(L("view.outline", "Outline"), systemImage: "list.bullet.indent").tag(ViewStyle.outline)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .frame(width: 90)
                    .help(L("picker.view.help", "Cambiar entre Kanban y Outline"))
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if controller.mode == .app {
                    FilterMenu(controller: controller)
                } else {
                    // Modo Libre only interprets/logs changes at save time
                    // (spec change: no more live watcher) — give it an
                    // explicit, discoverable Save action alongside ⌘S.
                    Button {
                        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                    } label: {
                        Label(L("action.save", "Guardar"), systemImage: "square.and.arrow.down")
                    }
                    .help(L("action.save.help", "Guardar e interpretar los cambios (⌘S)"))
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLog = true
                } label: {
                    Label(L("log.open", "Ver historial"), systemImage: "clock.arrow.circlepath")
                }
                .help(L("log.open", "Ver historial"))
            }
        }
        .searchable(text: $controller.filter.query, placement: .toolbar, prompt: L("search.prompt", "Buscar tareas"))
        .overlay {
            if controller.mode == .app, controller.filter.isActive,
               controller.filter.displayOrder(in: controller.document).isEmpty {
                NoMatchesView(controller: controller)
            }
        }
        .sheet(isPresented: $showLog) {
            LogPanelView(controller: controller)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.checkForExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.checkForExternalChange()
        }
        .alert(
            L("external.title", "El archivo cambió en el disco"),
            isPresented: Binding(
                get: { controller.pendingExternalText != nil },
                set: { _ in }
            )
        ) {
            Button(L("external.reload", "Recargar desde el disco"), role: .destructive) { controller.reloadFromDisk() }
            Button(L("external.keep", "Conservar mi versión"), role: .cancel) { controller.keepLocalVersion() }
        } message: {
            Text(L("external.message", "Otra aplicación modificó este archivo y tienes cambios sin guardar. Recargar descarta tus cambios."))
        }
        .onAppear {
            if let fileURL {
                RecentFilesStore.shared.recordOpened(fileURL)
            }
        }
        .onChange(of: fileURL) {
            if let fileURL {
                controller.bindToFileURL(fileURL)
                RecentFilesStore.shared.recordOpened(fileURL)
            }
        }
        .alert(
            L("error.title", "Error"),
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    /// The window opens exactly as wide as it needs to be to show every
    /// Kanban column with no scrolling — not some arbitrary fixed size —
    /// capped so a document with many sections doesn't try to open wider
    /// than a reasonable screen.
    private var idealWindowWidth: CGFloat {
        guard controller.mode == .app, controller.viewStyle == .kanban else { return 760 }
        let width = KanbanView.idealContentWidth(controller: controller)
        return min(width, 1400)
    }
}
