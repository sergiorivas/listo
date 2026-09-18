import Foundation

/// The app's translations, in code rather than a `.xcstrings` String
/// Catalog: `swift build` (outside Xcode) only copies `.xcstrings` files
/// verbatim instead of compiling them into per-language `.strings`, so
/// `NSLocalizedString`/`Bundle.localizedString` against one is a silent
/// no-op under SwiftPM. A plain table sidesteps that entirely and, as a
/// bonus, supports switching language at runtime without relaunching.
enum LocalizationTable {
    static let strings: [String: [String: String]] = [
        "picker.mode": ["es": "Modo", "en": "Mode"],
        "picker.view": ["es": "Vista", "en": "View"],
        "mode.app": ["es": "App", "en": "App"],
        "mode.free": ["es": "Libre", "en": "Free"],
        "view.kanban": ["es": "Kanban", "en": "Kanban"],
        "view.outline": ["es": "Outline", "en": "Outline"],
        "log.open": ["es": "Ver historial", "en": "View history"],
        "action.save": ["es": "Guardar", "en": "Save"],
        "action.save.help": [
            "es": "Guardar e interpretar los cambios (⌘S)",
            "en": "Save and interpret changes (⌘S)",
        ],
        "error.title": ["es": "Error", "en": "Error"],
        "common.close": ["es": "Cerrar", "en": "Close"],

        "conflict.merged": [
            "es": "Se fusionaron los cambios locales con los del disco.",
            "en": "Local changes were merged with the ones on disk.",
        ],
        "conflict.unresolved": [
            "es": "El archivo cambió por fuera y no se pudo fusionar automáticamente (configurá una clave de API en Ajustes).",
            "en": "The file changed externally and couldn't be merged automatically (set an API key in Settings).",
        ],

        "task.add.placeholder": ["es": "Nueva tarea…", "en": "New task…"],
        "task.indent": ["es": "Indentar", "en": "Indent"],
        "task.outdent": ["es": "Quitar indentación", "en": "Outdent"],
        "task.moveTo": ["es": "Mover a…", "en": "Move to…"],
        "task.delete": ["es": "Eliminar", "en": "Delete"],
        "section.delete": ["es": "Eliminar sección", "en": "Delete section"],
        "column.collapse": ["es": "Colapsar columna", "en": "Collapse column"],
        "column.expand": ["es": "Expandir columna", "en": "Expand column"],
        "section.delete.confirm.title": ["es": "¿Eliminar esta sección?", "en": "Delete this section?"],
        "section.delete.confirm.message": [
            "es": "Se eliminan también sus tareas y subsecciones.",
            "en": "This also removes its tasks and subsections.",
        ],
        "note.title": ["es": "Nota", "en": "Note"],
        "note.save": ["es": "Guardar", "en": "Save"],
        "note.add": ["es": "Agregar nota", "en": "Add note"],
        "note.edit": ["es": "Editar nota", "en": "Edit note"],

        "log.export.error": ["es": "No se pudo exportar", "en": "Couldn't export"],
        "log.title": ["es": "Historial", "en": "History"],
        "log.raw.help": ["es": "Ver como JSONL crudo", "en": "View as raw JSONL"],
        "log.export.jsonl": ["es": "Exportar como .jsonl", "en": "Export as .jsonl"],
        "log.export.text": ["es": "Exportar como texto legible", "en": "Export as readable text"],
        "log.revealInFinder": ["es": "Mostrar en Finder", "en": "Show in Finder"],
        "log.export": ["es": "Exportar…", "en": "Export…"],
        "log.empty": ["es": "Todavía no hay eventos.", "en": "No events yet."],

        "settings.llmProvider": ["es": "Proveedor", "en": "Provider"],
        "settings.llmProvider.anthropic": ["es": "Anthropic", "en": "Anthropic"],
        "settings.llmProvider.openRouter": ["es": "OpenRouter", "en": "OpenRouter"],
        "settings.apiKey.anthropic": ["es": "Clave de API de Anthropic", "en": "Anthropic API Key"],
        "settings.apiKey.openRouter": ["es": "Clave de API de OpenRouter", "en": "OpenRouter API Key"],
        "settings.apiKey.hint": [
            "es": "Se usa solo para interpretar cambios ambiguos en Modo Libre y para fusionar conflictos de sincronización. Se guarda en el Llavero de macOS — la app no cobra por su uso ni la envía a ningún otro lado.",
            "en": "Used only to interpret ambiguous Free Mode diffs and to reconcile hand-off conflicts. Stored in the macOS Keychain — the app doesn't charge for or forward this.",
        ],
        "settings.save": ["es": "Guardar", "en": "Save"],
        "settings.saved": ["es": "Guardado", "en": "Saved"],

        "settings.language": ["es": "Idioma", "en": "Language"],
        "settings.language.system": ["es": "Sistema", "en": "System"],
        "settings.theme": ["es": "Tema", "en": "Theme"],
        "settings.theme.system": ["es": "Sistema", "en": "System"],
        "settings.theme.light": ["es": "Claro", "en": "Light"],
        "settings.theme.dark": ["es": "Oscuro", "en": "Dark"],
        "settings.fontSize": ["es": "Tamaño de fuente", "en": "Font size"],
        "settings.fontSize.hint": [
            "es": "El resto de los tamaños de texto son relativos a este. También podés ajustarlo con ⌘+ / ⌘− en cualquier momento.",
            "en": "Every other text size is relative to this one. You can also adjust it anywhere with ⌘+ / ⌘−.",
        ],
        "settings.fontSize.reset": ["es": "Restablecer", "en": "Reset"],
        "settings.kanbanTitleOverflow": [
            "es": "Títulos largos en Kanban", "en": "Long titles in Kanban",
        ],
        "settings.kanbanTitleOverflow.truncate": ["es": "Truncar", "en": "Truncate"],
        "settings.kanbanTitleOverflow.wrap": ["es": "Ajustar altura", "en": "Wrap height"],
        "settings.section.appearance": ["es": "Apariencia", "en": "Appearance"],
        "settings.section.assistant": ["es": "Asistente (opcional)", "en": "Assistant (optional)"],

        "menu.newList": ["es": "Nueva lista", "en": "New list"],
        "menu.recent": ["es": "Abrir reciente", "en": "Open Recent"],
        "menu.recent.empty": ["es": "Sin archivos recientes", "en": "No recent files"],
        "menu.recent.clear": ["es": "Borrar recientes", "en": "Clear Recents"],
        "menu.view": ["es": "Ver", "en": "View"],
        "menu.task": ["es": "Tarea", "en": "Task"],
        "selection.clear": ["es": "Deseleccionar", "en": "Deselect"],

        "zoom.in": ["es": "Aumentar tamaño de fuente", "en": "Increase Font Size"],
        "zoom.out": ["es": "Reducir tamaño de fuente", "en": "Decrease Font Size"],
        "zoom.reset": ["es": "Restablecer tamaño de fuente", "en": "Reset Font Size"],
    ]
}
