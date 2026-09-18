import SwiftUI
import ListoEngine

/// Spec §07 ("Igual en cualquier idioma, de día o de noche") said no manual
/// switch was needed at launch — system language/appearance was enough.
/// This adds the manual overrides on top, live (no relaunch needed).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case es
    case en
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("settings.language.system", "Sistema")
        case .es: return "Español"
        case .en: return "English"
        }
    }

    /// The language code actually in effect once "system" is resolved
    /// against the user's preferred languages (falls back to Spanish, the
    /// catalog's source language, if neither es nor en is preferred).
    var resolvedCode: String {
        guard self == .system else { return rawValue }
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix(2))
            if code == "en" || code == "es" { return code }
        }
        return "es"
    }
}

/// How a Kanban card's title is shown when it's wider than the column:
/// clip it to one line (the historical behavior), or let the card grow
/// taller and wrap it in full.
enum KanbanTitleOverflow: String, CaseIterable, Identifiable {
    case truncate
    case wrap
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .truncate: return L("settings.kanbanTitleOverflow.truncate", "Truncar")
        case .wrap: return L("settings.kanbanTitleOverflow.wrap", "Ajustar altura")
        }
    }
}

/// Which LLM backend interprets ambiguous Modo Libre diffs and reconciles
/// hand-off conflicts (spec §05/§09: "trae tu propio LLM"). Each provider
/// keeps its own API key in the Keychain (`KeychainStore.Provider`), so
/// switching here doesn't lose the other one's key.
enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openRouter
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return L("settings.llmProvider.anthropic", "Anthropic")
        case .openRouter: return L("settings.llmProvider.openRouter", "OpenRouter")
        }
    }

    var keychainProvider: KeychainStore.Provider {
        switch self {
        case .anthropic: return .anthropic
        case .openRouter: return .openRouter
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("settings.theme.system", "Sistema")
        case .light: return L("settings.theme.light", "Claro")
        case .dark: return L("settings.theme.dark", "Oscuro")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Font sizes throughout the app are relative to this one base size, which
/// the user can bump with ⌘+/⌘− (and reset with ⌘0) — everything else
/// (headings, captions, monospaced editor text) scales off of it via
/// `AppSettings.font(_:)`.
enum RelativeTextStyle {
    case largeTitle
    case title2
    case title3
    case headline
    case body
    case caption

    var multiplier: CGFloat {
        switch self {
        case .largeTitle: return 1.6
        case .title2: return 1.3
        case .title3: return 1.15
        case .headline: return 1.05
        case .body: return 1.0
        case .caption: return 0.85
        }
    }
}

/// Central, observable settings store. Views that read `L(...)` or
/// `AppSettings.shared.font(...)` don't automatically re-render when these
/// change (they're plain function calls, not SwiftUI-tracked reads), so the
/// app's root views key themselves off `reloadToken` to force a fresh
/// render whenever anything here changes.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultFontSize: Double = 13
    static let minFontSize: Double = 10
    static let maxFontSize: Double = 24

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            reloadToken &+= 1
        }
    }
    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
            reloadToken &+= 1
        }
    }
    @Published var baseFontSize: Double {
        didSet {
            UserDefaults.standard.set(baseFontSize, forKey: Keys.fontSize)
            reloadToken &+= 1
        }
    }
    @Published var kanbanTitleOverflow: KanbanTitleOverflow {
        didSet {
            UserDefaults.standard.set(kanbanTitleOverflow.rawValue, forKey: Keys.kanbanTitleOverflow)
            reloadToken &+= 1
        }
    }
    @Published var llmProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: Keys.llmProvider)
            reloadToken &+= 1
        }
    }
    /// Bumped on every change above; views apply `.id(settings.reloadToken)`
    /// to force a full re-render (including their `L(...)` calls) without
    /// having to thread `@ObservedObject` reads through every leaf view.
    @Published private(set) var reloadToken: Int = 0

    private enum Keys {
        static let language = "listo.settings.language"
        static let theme = "listo.settings.theme"
        static let fontSize = "listo.settings.fontSize"
        static let kanbanTitleOverflow = "listo.settings.kanbanTitleOverflow"
        static let llmProvider = "listo.settings.llmProvider"
    }

    private init() {
        let defaults = UserDefaults.standard
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        let storedSize = defaults.double(forKey: Keys.fontSize)
        baseFontSize = storedSize > 0 ? storedSize : Self.defaultFontSize
        kanbanTitleOverflow = defaults.string(forKey: Keys.kanbanTitleOverflow)
            .flatMap(KanbanTitleOverflow.init(rawValue:)) ?? .truncate
        llmProvider = defaults.string(forKey: Keys.llmProvider)
            .flatMap(LLMProvider.init(rawValue:)) ?? .anthropic
    }

    var locale: Locale {
        language == .system ? .autoupdatingCurrent : Locale(identifier: language.rawValue)
    }

    func increaseFontSize() { baseFontSize = min(Self.maxFontSize, baseFontSize + 1) }
    func decreaseFontSize() { baseFontSize = max(Self.minFontSize, baseFontSize - 1) }
    func resetFontSize() { baseFontSize = Self.defaultFontSize }

    func font(_ style: RelativeTextStyle, design: Font.Design = .default, weight: Font.Weight = .regular) -> Font {
        .system(size: baseFontSize * style.multiplier, weight: weight, design: design)
    }

    func nsFontSize(_ style: RelativeTextStyle = .body) -> CGFloat {
        baseFontSize * style.multiplier
    }
}

/// Looks up `key` in the in-code localization table (see
/// `LocalizationTable.swift`), honoring the user's language override.
/// Falls back to `value` (the Spanish source text) if the key or the
/// resolved language is missing — the same fallback `NSLocalizedString`
/// would give, so call sites read identically to before.
func L(_ key: String, _ value: String) -> String {
    LocalizationTable.strings[key]?[AppSettings.shared.language.resolvedCode] ?? value
}
