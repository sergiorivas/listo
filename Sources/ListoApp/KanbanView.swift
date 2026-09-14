import SwiftUI
import ListoEngine

struct KanbanView: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared

    static let columnWidth: CGFloat = 340
    static let columnSpacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16

    /// The width that fits every column with no scrolling — used by
    /// `ContentView` to size the window so it opens exactly as wide as it
    /// needs to be, no wider.
    static func idealContentWidth(columnCount: Int) -> CGFloat {
        let count = max(columnCount, 1)
        return CGFloat(count) * columnWidth + CGFloat(count - 1) * columnSpacing + horizontalPadding * 2
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(controller.document.sections, id: \.id) { section in
                        KanbanColumn(controller: controller, section: section)
                            .frame(width: Self.columnWidth)
                    }
                }
                .padding(Self.horizontalPadding)
                // When the window is wider than the columns need (e.g.
                // maximized), center them instead of leaving all the slack
                // on the right; once content is wider than the visible
                // area this has no effect and normal scrolling takes over.
                .frame(minWidth: geometry.size.width, alignment: .center)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A single trash button for deleting a section — deliberately not a
/// `Menu`: with only one action, a `Menu` just adds a second, redundant
/// disclosure affordance next to the icon. Deleting a section takes its
/// tasks and any nested subsections with it, so it confirms first.
private struct SectionDeleteButton: View {
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

private struct KanbanColumn: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let section: ListoSection
    @State private var newTaskText = ""
    @State private var titleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
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
                .font(settings.font(.headline, design: .monospaced, weight: .semibold))
                .lineLimit(1)
                .onAppear { titleText = section.title }

                Spacer(minLength: 0)

                SectionDeleteButton { controller.deleteSection(sectionID: section.id) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.tasks, id: \.id) { task in
                        TaskChip(controller: controller, task: task)
                    }
                    ForEach(section.subsections, id: \.id) { sub in
                        KanbanSubgroup(controller: controller, section: sub)
                    }
                    if section.tasks.isEmpty && section.subsections.isEmpty {
                        // Empty section: just the column title, no illustrated
                        // empty state (spec §04/§09).
                        EmptyView()
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                TextField(
                    L("task.add.placeholder", "Nueva tarea…"),
                    text: $newTaskText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let trimmed = newTaskText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    controller.addTask(text: trimmed, toSectionID: section.id)
                    newTaskText = ""
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        }
    }
}

private struct KanbanSubgroup: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let section: ListoSection
    @State private var titleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
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
                .font(settings.font(.caption, weight: .bold))
                .foregroundStyle(.secondary)
                .onAppear { titleText = section.title }

                Spacer(minLength: 0)

                SectionDeleteButton { controller.deleteSection(sectionID: section.id) }
            }
            ForEach(section.tasks, id: \.id) { task in
                TaskChip(controller: controller, task: task)
            }
            ForEach(section.subsections, id: \.id) { sub in
                KanbanSubgroup(controller: controller, section: sub)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        }
    }
}

/// A Kanban card for one top-level task. Owns the single popover used for
/// editing this task's note — only a top-level task can have one (Listo's
/// tree is deliberately just task + subtask, and subtasks don't carry
/// notes), so `TaskRow` never attaches its own popover; it just bubbles a
/// `NoteEditTarget` up through `onEditNote` for its own row.
private struct TaskChip: View {
    @ObservedObject var controller: DocumentController
    let task: ListoTask
    @State private var noteEdit: NoteEditTarget?

    var body: some View {
        TaskRow(controller: controller, task: task, depth: 0, allowMove: true) { target in
            noteEdit = target
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .popover(item: $noteEdit) { target in
            NoteEditorPopover(target: target) { newText in
                controller.setNote(taskID: target.id, note: newText.isEmpty ? nil : newText)
                noteEdit = nil
            }
        }
    }
}

/// One task or subtask row. `depth` 0 is the top-level task, which can
/// carry a note and be indented into a subtask; `depth` 1 is a subtask,
/// which cannot — both rules are enforced here (disabling the action/
/// hiding the note UI) and in `ListoEditor` (`maxSubtaskDepth`, `setNote`).
private struct TaskRow: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let task: ListoTask
    let depth: Int
    /// Only a genuine top-level task can move to a different section.
    let allowMove: Bool
    let onEditNote: (NoteEditTarget) -> Void
    @State private var text = ""
    /// Whether the title is currently a live `TextField`. Click only
    /// selects the row (see `ownRow`'s doc comment below); this is what
    /// keeps a plain click from also dropping you into rename mode, which
    /// is what made right-click and Tab/⇧Tab-on-select unreliable before.
    @State private var isEditing = false
    @FocusState private var isRowFocused: Bool
    @FocusState private var isTextFieldFocused: Bool

    private static let maxDepth = ListoEditor.maxSubtaskDepth
    private var isSelected: Bool { controller.selectedTaskID == task.id }

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 4 : 2) {
            ownRow

            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(task.subtasks, id: \.id) { sub in
                        TaskRow(controller: controller, task: sub, depth: depth + 1, allowMove: false, onEditNote: onEditNote)
                    }
                }
                .padding(.leading, depth == 0 ? 18 : 14)
            }
        }
    }

    /// Just this task's own line + inline note — selectable/focusable/
    /// draggable/context-menu independent of its rendered subtasks, à la
    /// Things: a single click only selects the row (⇥/⇧⇥ then re-indents
    /// it, Return starts renaming it); double-clicking the title (or
    /// Return while selected) is what starts renaming. Right-click acts on
    /// whichever row you click, opening the menu for it without needing it
    /// to already be selected.
    private var ownRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    controller.selectedTaskID = task.id
                    isRowFocused = true
                    controller.toggle(taskID: task.id)
                } label: {
                    Image(systemName: task.state == .done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(task.state == .done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

                titleField

                if depth == 0, task.note == nil {
                    Button {
                        controller.selectedTaskID = task.id
                        isRowFocused = true
                        onEditNote(NoteEditTarget(id: task.id, initialText: ""))
                    } label: {
                        Image(systemName: "note.text.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.35)
                }
            }

            // Note content shown directly, no click needed — editing still
            // happens via the (shared, owned by TaskChip) popover, opened
            // by tapping the note itself. Top-level tasks only; subtasks
            // don't carry notes.
            if depth == 0, let note = task.note, !note.isEmpty {
                Text(note)
                    .font(settings.font(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
                    .onTapGesture {
                        controller.selectedTaskID = task.id
                        onEditNote(NoteEditTarget(id: task.id, initialText: note))
                    }
            }
        }
        .padding(4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .focusable()
        .focusEffectDisabled()
        .focused($isRowFocused)
        // `.simultaneousGesture` so selecting never steals the click from
        // the checkbox/note buttons; guarded against `isEditing` so a click
        // meant to place the cursor in an already-open text field doesn't
        // fight with it.
        .simultaneousGesture(TapGesture().onEnded {
            guard !isEditing else { return }
            controller.selectedTaskID = task.id
            isRowFocused = true
        })
        .onKeyPress { press in
            // Handles Tab/Shift+Tab/Return when the row is merely selected
            // (not text-editing) — the text field has its own handler for
            // while it's actively focused.
            guard isRowFocused, !isEditing else { return .ignored }
            switch press.key {
            case .tab:
                if press.modifiers.contains(.shift) {
                    controller.outdent(taskID: task.id)
                } else {
                    controller.indent(taskID: task.id)
                }
                return .handled
            case .return:
                beginEditing()
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear { text = task.text }
        .draggable(task.id.uuidString)
        .contextMenu {
            if depth == 0 {
                Button {
                    controller.selectedTaskID = task.id
                    onEditNote(NoteEditTarget(id: task.id, initialText: task.note ?? ""))
                } label: {
                    Label(
                        task.note == nil ? L("note.add", "Agregar nota") : L("note.edit", "Editar nota"),
                        systemImage: "note.text"
                    )
                }
                Divider()
            }
            Button {
                controller.indent(taskID: task.id)
            } label: {
                Label(L("task.indent", "Indentar"), systemImage: "increase.indent")
            }
            .disabled(depth >= Self.maxDepth)
            Button {
                controller.outdent(taskID: task.id)
            } label: {
                Label(L("task.outdent", "Quitar indentación"), systemImage: "decrease.indent")
            }
            .disabled(depth == 0)
            if allowMove {
                Menu {
                    ForEach(controller.document.sections, id: \.id) { s in
                        Button(s.title) { controller.move(taskID: task.id, toSectionID: s.id) }
                    }
                } label: {
                    Label(L("task.moveTo", "Mover a…"), systemImage: "arrow.turn.up.right")
                }
            }
            Divider()
            Button(role: .destructive) {
                controller.delete(taskID: task.id)
            } label: {
                Label(L("task.delete", "Eliminar"), systemImage: "trash")
            }
        }
    }

    /// Plain text when not editing (so a click just selects the row instead
    /// of always dropping into rename mode — that conflict was also what
    /// made right-click unreliable, since a click on the title used to hit
    /// a live `TextField` first); a `TextField` once `isEditing` is true.
    @ViewBuilder
    private var titleField: some View {
        if isEditing {
            TextField("", text: $text, onCommit: commitEditing)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(depth == 0 ? settings.font(.body) : settings.font(.caption))
                .focused($isTextFieldFocused)
                .onAppear { isTextFieldFocused = true }
                .onChange(of: isTextFieldFocused) { _, focused in
                    // Clicking away (another row, empty space, another
                    // control) commits instead of leaving an edit dangling.
                    if !focused { commitEditing() }
                }
                .onKeyPress { press in
                    switch press.key {
                    case .escape:
                        cancelEditing()
                        return .handled
                    case .tab:
                        // A rename gives the task a new content-derived id
                        // (`StableID`), so `task.id` below goes stale the
                        // instant `commitEditing()` actually renames it —
                        // chaining an indent/outdent onto it in that case
                        // would indent/outdent a task that no longer
                        // exists. Only chain it when nothing changed (a
                        // plain "Tab to indent" with an untouched field).
                        let renamed = wouldRename
                        commitEditing()
                        if !renamed {
                            if press.modifiers.contains(.shift) {
                                controller.outdent(taskID: task.id)
                            } else {
                                controller.indent(taskID: task.id)
                            }
                        }
                        return .handled
                    default:
                        return .ignored
                    }
                }
        } else {
            Text(task.text)
                .font(depth == 0 ? settings.font(.body) : settings.font(.caption))
                .strikethrough(task.state == .done)
                .foregroundStyle(task.state == .done ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEditing() }
        }
    }

    private func beginEditing() {
        text = task.text
        controller.selectedTaskID = task.id
        isEditing = true
    }

    /// Whether calling `commitEditing()` right now would actually rename
    /// the task (as opposed to a no-op revert of an untouched/blanked-out
    /// field).
    private var wouldRename: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != task.text
    }

    private func commitEditing() {
        // Idempotency guard: ending edit mode (`isEditing = false`) can
        // itself cause `isTextFieldFocused` to flip to false as the field
        // leaves the view tree, which re-fires the `onChange` above and
        // would otherwise call this a second time — using this same
        // (by-then-stale, already-renamed-away) `task.id` and blowing up
        // with "task not found".
        guard isEditing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        } else {
            text = task.text
        }
        isEditing = false
    }

    private func cancelEditing() {
        text = task.text
        isEditing = false
    }
}
