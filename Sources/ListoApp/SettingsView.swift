import SwiftUI
import ListoEngine

/// Adds manual language/theme/font-size overrides on top of the spec §07
/// defaults (system language, system appearance) — plus the §05/§09 "trae
/// tu propio LLM" API key. Everything here updates live; no relaunch needed.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKey: String = ""
    @State private var savedRecently = false

    var body: some View {
        Form {
            Section {
                Picker(L("settings.language", "Idioma"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Picker(L("settings.theme", "Tema"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                LabeledContent(L("settings.fontSize", "Tamaño de fuente")) {
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

                Picker(
                    L("settings.kanbanTitleOverflow", "Títulos largos en Kanban"),
                    selection: $settings.kanbanTitleOverflow
                ) {
                    ForEach(KanbanTitleOverflow.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                if settings.baseFontSize != AppSettings.defaultFontSize {
                    LabeledContent("") {
                        Button(L("settings.fontSize.reset", "Restablecer")) {
                            settings.resetFontSize()
                        }
                        .controlSize(.small)
                    }
                }

                Text(L(
                    "settings.fontSize.hint",
                    "El resto de los tamaños de texto son relativos a este. También podés ajustarlo con ⌘+ / ⌘− en cualquier momento."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L("settings.section.appearance", "Apariencia"), systemImage: "paintbrush")
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

                if settings.firstSectionBackgroundColor.hexString != AppSettings.defaultFirstSectionBackground.hexString
                    || settings.lastSectionBackgroundColor.hexString != AppSettings.defaultLastSectionBackground.hexString {
                    LabeledContent("") {
                        Button(L("settings.fontSize.reset", "Restablecer")) {
                            settings.resetSectionBackgrounds()
                        }
                        .controlSize(.small)
                    }
                }

                Text(L(
                    "settings.sectionBg.hint",
                    "Pensado para la primera columna (Hoy, Enfoque, …) y la última (Hecho, …), independientemente de cómo se llamen — se aplican por posición, no por nombre."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L("settings.section.columnColors", "Colores de columnas"), systemImage: "paintpalette")
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

                Text(L(
                    "settings.doneMoveDelay.hint",
                    "Al marcar una tarea, si existe una sección cuyo nombre contenga \"Done\", \"Completed\" o \"Finished\", se la mueve al final de esa sección después de esta espera. En 0 la función queda desactivada."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L("settings.section.behavior", "Comportamiento"), systemImage: "checkmark.circle")
            }

            Section {
                Picker(L("settings.llmProvider", "Proveedor"), selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: settings.llmProvider) { _, _ in
                    reloadKeyField()
                    savedRecently = false
                }

                SecureField(apiKeyLabel, text: $apiKey)

                LabeledContent("") {
                    HStack(spacing: 8) {
                        Button {
                            if apiKey.isEmpty {
                                KeychainStore.clear(provider: settings.llmProvider.keychainProvider)
                            } else {
                                KeychainStore.save(apiKey: apiKey, provider: settings.llmProvider.keychainProvider)
                            }
                            savedRecently = true
                        } label: {
                            Label(L("settings.save", "Guardar"), systemImage: "checkmark.circle")
                        }
                        if savedRecently {
                            Text(L("settings.saved", "Guardado"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(L(
                    "settings.apiKey.hint",
                    "Se usa solo para interpretar cambios ambiguos en Modo Libre y para fusionar conflictos de sincronización. Se guarda en el Llavero de macOS — la app no cobra por su uso ni la envía a ningún otro lado."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L("settings.section.assistant", "Asistente (opcional)"), systemImage: "key")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { reloadKeyField() }
    }

    private var apiKeyLabel: String {
        switch settings.llmProvider {
        case .anthropic: return L("settings.apiKey.anthropic", "Clave de API de Anthropic")
        case .openRouter: return L("settings.apiKey.openRouter", "Clave de API de OpenRouter")
        }
    }

    private func reloadKeyField() {
        apiKey = KeychainStore.loadAPIKey(provider: settings.llmProvider.keychainProvider) ?? ""
    }

    private var doneMoveDelayLabel: String {
        settings.doneMoveDelaySeconds == 0
            ? L("settings.doneMoveDelay.disabled", "Desactivado")
            : "\(Int(settings.doneMoveDelaySeconds))s"
    }
}
