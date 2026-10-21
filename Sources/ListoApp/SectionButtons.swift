import SwiftUI

/// Sits next to `SectionDeleteButton` in a section/column header — adds a
/// new, empty task at the end of that section and immediately focuses it
/// for typing (`DocumentController.addTaskAndEdit`). Replaces the
/// always-visible "new task…" field each section used to end with; Return
/// from an existing row (`insertSiblingAndEdit`) is the other way in.
struct SectionAddTaskButton: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("section.addTask", "Agregar tarea"))
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
        Button {
            showConfirm = true
        } label: {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("section.delete", "Eliminar sección"))
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
