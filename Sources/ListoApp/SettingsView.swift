import SwiftUI
import ListoEngine

/// Adds manual language/theme/font-size overrides on top of the spec §07
/// defaults (system language, system appearance) — plus the §05/§09 "trae
/// tu propio LLM" API key. Everything here updates live; no relaunch needed.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKey: String = KeychainStore.loadAPIKey() ?? ""
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
                SecureField(
                    L("settings.apiKey", "Clave de API de Anthropic"),
                    text: $apiKey
                )

                LabeledContent("") {
                    HStack(spacing: 8) {
                        Button {
                            if apiKey.isEmpty {
                                KeychainStore.clear()
                            } else {
                                KeychainStore.save(apiKey: apiKey)
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
    }
}
