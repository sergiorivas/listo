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
        .toolbar {
            ToolbarItemGroup {
                Picker(L("picker.mode", "Modo"), selection: $controller.mode) {
                    Text(L("mode.app", "App")).tag(EditMode.app)
                    Text(L("mode.free", "Libre")).tag(EditMode.freeEdit)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if controller.mode == .app {
                    Picker(L("picker.view", "Vista"), selection: $controller.viewStyle) {
                        Label(L("view.kanban", "Kanban"), systemImage: "rectangle.split.3x1").tag(ViewStyle.kanban)
                        Label(L("view.outline", "Outline"), systemImage: "list.bullet.indent").tag(ViewStyle.outline)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .frame(width: 90)
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

                Button {
                    showLog = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help(L("log.open", "Ver historial"))
            }
        }
        .sheet(isPresented: $showLog) {
            LogPanelView(controller: controller)
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
