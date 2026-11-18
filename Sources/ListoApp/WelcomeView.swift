import SwiftUI
import AppKit

/// What the user picked on the welcome window's last page.
enum WelcomeChoice {
    case newDocument
    case openFile
    /// Closed the window or pressed Skip/Esc.
    case dismissed
}

/// Its own class so `ListoAppDelegate` can tell this window's close apart
/// from a document window's (which triggers the "nothing open" prompt).
final class WelcomeNSWindow: NSWindow {}

/// The first-launch welcome: a few short pages on what Listo is, run as an
/// app-modal window so the launch routine can wait for the answer and then
/// carry on (new document / open panel / the usual start prompt).
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private var choice: WelcomeChoice = .dismissed
    private var window: WelcomeNSWindow?

    static func runModal() -> WelcomeChoice {
        let presenter = WelcomeWindow()
        return presenter.run()
    }

    private func run() -> WelcomeChoice {
        let window = WelcomeNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = AppSettings.shared.theme.nsAppearance
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] choice in
            self?.finish(choice)
        }
        .environment(\.locale, AppSettings.shared.locale))
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return choice
    }

    private func finish(_ choice: WelcomeChoice) {
        self.choice = choice
        window?.close() // → windowWillClose stops the modal session
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

// MARK: - Content

private struct WelcomeView: View {
    let onFinish: (WelcomeChoice) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var page = 0
    @State private var forward = true

    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: FilePage()
                    case 1: ViewsPage()
                    case 2: KeyboardPage()
                    default: QuickAddPage(shortcut: settings.quickAddShortcut.displayString)
                    }
                }
                .id(page)
                .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(width: 540, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageTransition: AnyTransition {
        guard !Motion.reduceMotion else { return .opacity }
        let edge: Edge = forward ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to newPage: Int) {
        forward = newPage > page
        withAnimation(Motion.snappy) { page = newPage }
    }

    private var isLastPage: Bool { page == Self.pageCount - 1 }

    private var footer: some View {
        HStack {
            Button(L("welcome.skip", "Omitir")) { onFinish(.dismissed) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .onTapGesture { go(to: index) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L("welcome.pageOf", "Página") + " \(page + 1) / \(Self.pageCount)")

            Spacer()

            HStack(spacing: 8) {
                if page > 0 {
                    Button(L("welcome.back", "Atrás")) { go(to: page - 1) }
                }
                if isLastPage {
                    Button(L("start.openFile", "Abrir archivo…")) { onFinish(.openFile) }
                    Button(L("welcome.newList", "Crear una lista")) { onFinish(.newDocument) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("welcome.continue", "Continuar")) { go(to: page + 1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
    }
}

/// Icon + title + body, the shared top of every page.
private struct PageHeader: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 48)
            Text(title)
                .font(.title.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FilePage: View {
    var body: some View {
        VStack(spacing: 22) {
            PageHeader(
                symbol: "checklist",
                title: L("welcome.file.title", "Te damos la bienvenida a Listo"),
                message: L("welcome.file.message",
                           "Tus tareas viven en un archivo Markdown común. Sin cuentas ni base de datos: el archivo es tuyo y se abre con cualquier editor."))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("welcome.file.sample",
                       "## Por hacer\n- [ ] Pagar el alquiler !!!\n  - [ ] Transferir\n- [x] Llamar a mamá"))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Text(L("welcome.file.legend",
                       "Cada «##» es una columna, cada «- [ ]» una tarea, y lo indentado, una subtarea."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }
}

private struct ViewsPage: View {
    var body: some View {
        VStack(spacing: 22) {
            PageHeader(
                symbol: "rectangle.split.3x1",
                title: L("welcome.views.title", "Tres formas de verla"),
                message: L("welcome.views.message", "Cambiá entre ellas desde la barra de herramientas; las tres editan el mismo archivo."))

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "rectangle.split.3x1",
                           title: L("view.kanban", "Kanban"),
                           detail: L("welcome.views.kanban", "Una columna por sección. Arrastrá tarjetas o usá ⌘← / ⌘→."))
                FeatureRow(symbol: "list.bullet.indent",
                           title: L("view.outline", "Outline"),
                           detail: L("welcome.views.outline", "Todo el documento como esquema, con secciones plegables."))
                FeatureRow(symbol: "doc.plaintext",
                           title: L("welcome.views.free", "Modo Libre"),
                           detail: L("welcome.views.freeDetail", "El Markdown tal cual. Listo lo interpreta al guardar (⌘S)."))
            }
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct KeyboardPage: View {
    private var shortcuts: [(keys: String, action: String)] {
        [
            ("⌘N", L("task.new", "Nueva tarea")),
            ("↩", L("welcome.keys.return", "Otra tarea debajo")),
            ("⇥  ⇧⇥", L("welcome.keys.tab", "Convertir en subtarea / volver")),
            ("Space", L("welcome.keys.space", "Marcar como hecha")),
            ("⌘↑  ⌘↓", L("welcome.keys.reorder", "Reordenar")),
            ("⌘F", L("welcome.keys.find", "Buscar y filtrar")),
            ("⌘Z", L("edit.undo", "Deshacer")),
        ]
    }

    var body: some View {
        VStack(spacing: 18) {
            PageHeader(
                symbol: "keyboard",
                title: L("welcome.keys.title", "Hecha para el teclado"),
                message: L("welcome.keys.message", "Seleccioná una tarea con ↑/↓ y trabajá sin tocar el mouse."))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(shortcuts, id: \.keys) { item in
                    GridRow {
                        Text(item.keys)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .gridColumnAlignment(.trailing)
                        Text(item.action).foregroundStyle(.secondary)
                    }
                }
            }

            Text(L("welcome.keys.tokens", "En el título: «!!!» da prioridad, «@2026-12-01» una fecha y «#trabajo» una etiqueta."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QuickAddPage: View {
    let shortcut: String

    var body: some View {
        VStack(spacing: 26) {
            PageHeader(
                symbol: "menubar.arrow.up.rectangle",
                title: L("welcome.quick.title", "Anotá desde cualquier app"),
                message: L("welcome.quick.message",
                           "Este atajo abre un panel pequeño para agregar a la primera columna, sin dejar lo que estás haciendo. También está en el ícono de la barra de menús."))

            Text(shortcut)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))

            Text(L("welcome.quick.settings", "Podés cambiarlo en Ajustes ▸ Barra de menús."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}
