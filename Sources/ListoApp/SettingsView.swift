import SwiftUI
import ListoEngine

/// Adds manual language/theme/font-size overrides on top of the spec §07
/// defaults (system language, system appearance) — plus the §05/§09 "trae
/// tu propio LLM" API key. Everything here updates live; no relaunch needed.
///
/// Toolbar tabs (General / Appearance / Shortcuts / Assistant), the usual
/// macOS Settings layout: it used to be one long form with five sections,
/// which only grew with every new option.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(L("settings.tab.general", "General"), systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label(L("settings.section.appearance", "Apariencia"), systemImage: "paintbrush") }
            ShortcutSettingsTab()
                .tabItem { Label(L("settings.tab.shortcuts", "Atajos"), systemImage: "keyboard") }
            AssistantSettingsTab()
                .tabItem { Label(L("settings.tab.assistant", "Asistente"), systemImage: "key") }
        }
        .frame(width: 500)
    }
}

/// The caption under a group of settings.
private struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small "Reset" button, shown only while `isVisible` (the value differs
/// from its default) — inline next to the control it resets, instead of on
/// a row of its own.
private struct ResetButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(L("settings.fontSize.reset", "Restablecer"), action: action)
            .controlSize(.small)
            .opacity(isVisible ? 1 : 0)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
    }
}

private extension View {
    func settingsForm() -> some View {
        formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("settings.language", "Idioma"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            Section {
                Toggle(
                    L("settings.completionSound", "Sonido al completar una tarea"),
                    isOn: $settings.completionSoundEnabled
                )

                Toggle(
                    L("settings.deleteSound", "Sonido al eliminar una tarea"),
                    isOn: $settings.deleteSoundEnabled
                )

                Toggle(
                    L("settings.outdentAbsorbs", "Al desindentar, las subtareas siguientes pasan a ser suyas"),
                    isOn: $settings.outdentAbsorbsSiblings
                )
            } header: {
                Label(L("settings.section.behavior", "Comportamiento"), systemImage: "checkmark.circle")
            }

            Section {
                LabeledContent(L("settings.doneMoveDelay", "Mover a Hecho después de")) {
                    Stepper(
                        value: $settings.doneMoveDelaySeconds,
                        in: AppSettings.minDoneMoveDelaySeconds...AppSettings.maxDoneMoveDelaySeconds,
                        step: 1
                    ) {
                        Text(doneMoveDelayLabel)
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }

                LabeledContent(L("settings.doneSectionNames", "Nombres de la sección Hecho")) {
                    HStack(spacing: 8) {
                        ResetButton(isVisible: settings.doneSectionNames != AppSettings.defaultDoneSectionNames) {
                            settings.doneSectionNames = AppSettings.defaultDoneSectionNames
                        }
                        TextField("", text: $settings.doneSectionNames, prompt: Text(AppSettings.defaultDoneSectionNames))
                            .labelsHidden()
                            .frame(minWidth: 180)
                    }
                }
                .disabled(settings.doneMoveDelaySeconds == 0)

                SettingsHint(text: L(
                    "settings.doneMoveDelay.hint",
                    "Al marcar una tarea, se la mueve al final de la primera sección cuyo nombre contenga alguno de estos nombres (separados por comas), después de esta espera. En 0 la función queda desactivada."
                ))
            } header: {
                Label(L("settings.section.doneMove", "Tareas completadas"), systemImage: "tray.and.arrow.down")
            }
        }
        .settingsForm()
    }

    private var doneMoveDelayLabel: String {
        settings.doneMoveDelaySeconds == 0
            ? L("settings.doneMoveDelay.disabled", "Desactivado")
            : "\(Int(settings.doneMoveDelaySeconds))s"
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("settings.theme", "Tema"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                LabeledContent(L("settings.fontSize", "Tamaño de fuente")) {
                    HStack(spacing: 8) {
                        ResetButton(isVisible: settings.baseFontSize != AppSettings.defaultFontSize) {
                            settings.resetFontSize()
                        }
                        Stepper(
                            value: $settings.baseFontSize,
                            in: AppSettings.minFontSize...AppSettings.maxFontSize,
                            step: 1
                        ) {
                            Text("\(Int(settings.baseFontSize))pt")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                Picker(
                    L("settings.kanbanTitleOverflow", "Títulos largos en Kanban"),
                    selection: $settings.kanbanTitleOverflow
                ) {
                    ForEach(KanbanTitleOverflow.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                SettingsHint(text: L(
                    "settings.fontSize.hint",
                    "El resto de los tamaños de texto son relativos a este. También podés ajustarlo con ⌘+ / ⌘− en cualquier momento."
                ))
            }

            Section {
                Toggle(
                    L("settings.firstSectionBg", "Colorear la primera columna"),
                    isOn: $settings.firstSectionBackgroundEnabled
                )
                if settings.firstSectionBackgroundEnabled {
                    ColorPicker(
                        L("settings.firstSectionBg.color", "Color"),
                        selection: $settings.firstSectionBackgroundColor,
                        supportsOpacity: false
                    )
                }

                Toggle(
                    L("settings.lastSectionBg", "Colorear la última columna"),
                    isOn: $settings.lastSectionBackgroundEnabled
                )
                if settings.lastSectionBackgroundEnabled {
                    ColorPicker(
                        L("settings.lastSectionBg.color", "Color"),
                        selection: $settings.lastSectionBackgroundColor,
                        supportsOpacity: false
                    )
                }

                SettingsHint(text: L(
                    "settings.sectionBg.hint",
                    "Pensado para la primera columna (Hoy, Enfoque, …) y la última (Hecho, …), independientemente de cómo se llamen — se aplican por posición, no por nombre."
                ))
            } header: {
                HStack {
                    Label(L("settings.section.columnColors", "Colores de columnas"), systemImage: "paintpalette")
                    Spacer()
                    ResetButton(isVisible: colorsChanged) { settings.resetSectionBackgrounds() }
                }
            }
        }
        .settingsForm()
    }

    private var colorsChanged: Bool {
        settings.firstSectionBackgroundColor.hexString != AppSettings.defaultFirstSectionBackground.hexString
            || settings.lastSectionBackgroundColor.hexString != AppSettings.defaultLastSectionBackground.hexString
    }
}

// MARK: - Shortcuts

private struct ShortcutSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var quickAdd = QuickAddController.shared

    var body: some View {
        Form {
            Section {
                LabeledContent(L("settings.hotKey", "Atajo global")) {
                    HStack(spacing: 8) {
                        ResetButton(isVisible: settings.quickAddShortcut != .defaultQuickAdd) {
                            settings.quickAddShortcut = .defaultQuickAdd
                        }
                        HotKeyRecorder(shortcut: $settings.quickAddShortcut)
                    }
                }

                if quickAdd.hotKeyUnavailable {
                    Label(
                        L("settings.hotKey.unavailable", "Esta combinación ya la usa otra app. Elegí otra."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                }

                SettingsHint(text: L(
                    "settings.hotKey.hint",
                    "Abre el panel de la barra de menús desde cualquier app: las 3 primeras tareas de la primera columna y un campo para agregar una. Hacé clic en el atajo y presioná la nueva combinación (con ⌘, ⌥ o ⌃); Esc cancela."
                ))
            } header: {
                Label(L("settings.section.quickAdd", "Barra de menús"), systemImage: "menubar.rectangle")
            }

            Section {
                ForEach(Self.reference, id: \.keys) { row in
                    LabeledContent(L(row.key, row.fallback)) {
                        Text(row.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label(L("settings.section.keyReference", "Atajos del tablero"), systemImage: "command")
            }
        }
        .settingsForm()
    }

    /// Read-only cheat sheet of the board's own shortcuts (they live in the
    /// menus; listed here so they can be found in one place).
    private static let reference: [(key: String, fallback: String, keys: String)] = [
        ("task.new", "Nueva tarea", "⌘N"),
        ("task.toggleDone", "Marcar/desmarcar como hecha", "Space"),
        ("task.indent", "Indentar", "⇥  ⌘]"),
        ("task.outdent", "Quitar indentación", "⇧⇥  ⌘["),
        ("settings.ref.reorder", "Reordenar", "⌘↑ ⌘↓"),
        ("settings.ref.moveColumn", "Mover a la columna vecina", "⌘← ⌘→"),
        ("settings.ref.extend", "Ampliar selección", "⇧↑ ⇧↓"),
        ("task.priority", "Prioridad", "⌥⌘1 ⌥⌘2 ⌥⌘3 ⌥⌘0"),
        ("task.split", "Dividir en tareas", "⌘T"),
        ("task.group", "Agrupar en una tarea", "⌘G"),
        ("settings.ref.views", "Kanban / Outline / Modo Libre", "⌘1 ⌘2 ⌘3"),
        ("search.prompt", "Buscar tareas", "⌘F"),
    ]
}

// MARK: - Assistant

private struct AssistantSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKey: String = ""
    @State private var savedRecently = false
    @State private var test: ConnectionTest = .idle

    private enum ConnectionTest: Equatable {
        case idle, running, succeeded
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Picker(L("settings.llmProvider", "Proveedor"), selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: settings.llmProvider) { _, _ in
                    reloadKeyField()
                    savedRecently = false
                    test = .idle
                }

                SecureField(apiKeyLabel, text: $apiKey)
                    .onChange(of: apiKey) { _, _ in
                        savedRecently = false
                        test = .idle
                    }

                LabeledContent("") {
                    HStack(spacing: 8) {
                        testStatus
                        Button {
                            runTest()
                        } label: {
                            Label(L("settings.test", "Probar conexión"), systemImage: "bolt.horizontal")
                        }
                        .disabled(apiKey.isEmpty || test == .running)

                        Button {
                            if apiKey.isEmpty {
                                KeychainStore.clear(provider: settings.llmProvider.keychainProvider)
                            } else {
                                KeychainStore.save(apiKey: apiKey, provider: settings.llmProvider.keychainProvider)
                            }
                            savedRecently = true
                        } label: {
                            Label(
                                savedRecently ? L("settings.saved", "Guardado") : L("settings.save", "Guardar"),
                                systemImage: savedRecently ? "checkmark.circle.fill" : "checkmark.circle"
                            )
                        }
                        .disabled(savedRecently)
                    }
                }

                if case .failed(let reason) = test {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                SettingsHint(text: L(
                    "settings.apiKey.hint",
                    "Se usa solo para interpretar cambios ambiguos en Modo Libre y para fusionar conflictos de sincronización. Se guarda en el Llavero de macOS — la app no cobra por su uso ni la envía a ningún otro lado."
                ))
            } header: {
                Label(L("settings.section.assistant", "Asistente (opcional)"), systemImage: "key")
            }
        }
        .settingsForm()
        .onAppear { reloadKeyField() }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle, .failed:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Label(L("settings.test.ok", "Funciona"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
                .transition(.opacity)
        }
    }

    /// Checks the key in the field (saved or not) with one tiny request.
    private func runTest() {
        let key = apiKey
        let client: LLMClient = switch settings.llmProvider {
        case .anthropic: AnthropicLLMClient(apiKey: key)
        case .openRouter: OpenRouterLLMClient(apiKey: key)
        }
        test = .running
        Task {
            do {
                try await client.testConnection()
                await MainActor.run { withAnimation(Motion.fade) { test = .succeeded } }
            } catch {
                let reason = Self.describe(error)
                await MainActor.run { withAnimation(Motion.fade) { test = .failed(reason) } }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case LLMError.badResponse(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? L("settings.test.failed", "La conexión falló.")
                : L("settings.test.failed", "La conexión falló.") + " " + String(trimmed.prefix(240))
        default:
            return L("settings.test.failed", "La conexión falló.") + " " + error.localizedDescription
        }
    }

    private var apiKeyLabel: String {
        switch settings.llmProvider {
        case .anthropic: return L("settings.apiKey.anthropic", "Clave de API de Anthropic")
        case .openRouter: return L("settings.apiKey.openRouter", "Clave de API de OpenRouter")
        }
    }

    private func reloadKeyField() {
        apiKey = KeychainStore.loadAPIKey(provider: settings.llmProvider.keychainProvider) ?? ""
        savedRecently = false
    }
}
