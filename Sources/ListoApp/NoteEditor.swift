import SwiftUI

/// Identifies which task's note is being edited, carrying the text the
/// editor should start from.
///
/// Used with `.popover(item:)` rather than `.popover(isPresented:)` plus a
/// separately-managed `@State` string: `.popover(item:)` constructs its
/// content fresh every time `item` goes from `nil` to non-`nil`, so the
/// editor can't ever open showing stale or empty text left over from a
/// previous popover instance — which is what "editing a note doesn't show
/// the current content" turned out to be.
struct NoteEditTarget: Identifiable {
    let id: UUID
    let initialText: String
}

struct NoteEditorPopover: View {
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    let hadNote: Bool
    let onSave: (String) -> Void

    init(target: NoteEditTarget, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: target.initialText)
        hadNote = !target.initialText.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("note.title", "Nota"))
                .font(AppSettings.shared.font(.headline))
            TextEditor(text: $text)
                .font(AppSettings.shared.font(.body, design: .monospaced))
                .frame(width: 320, height: 160)
            HStack {
                // Saving an empty note removes it (the callers treat "" as
                // nil), so this is just a clearer way to say so.
                if hadNote {
                    Button(L("note.delete", "Eliminar nota"), role: .destructive) {
                        onSave("")
                    }
                }
                Spacer()
                Button(L("note.cancel", "Cancelar")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("note.save", "Guardar")) {
                    onSave(text)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help(L("note.save.help", "Guardar (⌘↩)"))
            }
        }
        .padding()
    }
}
