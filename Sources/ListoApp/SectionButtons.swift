import SwiftUI
import ListoEngine

/// A small icon button for section/column headers: a 24pt target (the bare
/// glyph was a few points wide) that lights up on hover so it reads as
/// clickable.
struct HeaderIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.quick, value: isHovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Sits next to `SectionDeleteButton` in a section/column header — adds a
/// new, empty task at the end of that section and immediately focuses it
/// for typing (`DocumentController.addTaskAndEdit`). Replaces the
/// always-visible "new task…" field each section used to end with; Return
/// from an existing row (`insertSiblingAndEdit`) is the other way in.
struct SectionAddTaskButton: View {
    let onAdd: () -> Void

    var body: some View {
        HeaderIconButton(systemImage: "plus", label: L("section.addTask", "Agregar tarea"), action: onAdd)
    }
}

/// A single trash button for deleting a section — deliberately not a
/// `Menu`: with only one action, a `Menu` just adds a second, redundant
/// disclosure affordance next to the icon. Deleting a section takes its
/// tasks and any nested subsections with it, so it confirms first.
struct SectionDeleteButton: View {
    let onDelete: () -> Void
    @State private var showConfirm = false

    var body: some View {
        HeaderIconButton(systemImage: "trash", label: L("section.delete", "Eliminar sección")) {
            showConfirm = true
        }
        .confirmationDialog(
            L("section.delete.confirm.title", "¿Eliminar esta sección?"),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(L("task.delete", "Eliminar"), role: .destructive, action: onDelete)
        } message: {
            Text(L("section.delete.confirm.message", "Se eliminan también sus tareas y subsecciones."))
        }
    }
}

/// The add/delete pair of a section header. Revealed while the header is
/// hovered so a board of many columns isn't a wall of `+`/trash icons; the
/// buttons keep their accessibility labels while hidden, and the delete one
/// sits apart from `+` so the destructive action isn't an accidental click.
struct SectionHeaderActions: View {
    let isVisible: Bool
    let onAdd: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            SectionAddTaskButton(onAdd: onAdd)
            SectionDeleteButton(onDelete: onDelete)
                .padding(.leading, 6)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(Motion.quick, value: isVisible)
    }
}

/// The editable title of a column / heading, shared by Kanban columns,
/// subgroups and Outline sections. Takes focus when the section was just
/// created (`DocumentController.focusSectionID`) so it can be named at once.
struct SectionTitleField: View {
    @ObservedObject var controller: DocumentController
    let section: ListoSection
    let font: Font
    var color: Color = .primary
    @State private var titleText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $titleText, onCommit: {
            let trimmed = titleText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed != section.title {
                controller.renameSection(sectionID: section.id, newTitle: trimmed)
            } else {
                titleText = section.title
            }
        })
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .accessibilityLabel(L("section.title", "Título de la sección"))
        .onAppear {
            titleText = section.title
            claimFocusIfRequested()
        }
        .onChange(of: controller.focusSectionID) { claimFocusIfRequested() }
    }

    private func claimFocusIfRequested() {
        guard controller.focusSectionID == section.id else { return }
        controller.focusSectionID = nil
        // Same one-tick deferral as the task title field (see `TaskTitleField`).
        DispatchQueue.main.async { isFocused = true }
    }
}

/// Shown instead of the board when the file has no sections at all.
struct EmptyBoardView: View {
    let onAddSection: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(L("board.empty.title", "Aún no hay columnas"))
                .font(.headline)
            Text(L("board.empty.message", "Agrega una columna para empezar a organizar tus tareas."))
                .foregroundStyle(.secondary)
            Button(action: onAddSection) {
                Label(L("section.add", "Agregar columna"), systemImage: "plus")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "add a column" affordance at the end of the board (a dashed ghost
/// column in Kanban, a text button in Outline).
struct AddSectionButton: View {
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onAdd) {
            Label(L("section.add", "Agregar columna"), systemImage: "plus")
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.quick, value: isHovering)
    }
}
