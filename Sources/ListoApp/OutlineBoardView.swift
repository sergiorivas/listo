import SwiftUI
import ListoEngine

struct OutlineBoardView: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(controller.document.sections, id: \.id) { section in
                    OutlineSection(controller: controller, section: section, depth: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sits next to `SectionDeleteButton` in a section header — adds a new,
/// empty task at the end of that section and immediately focuses it for
/// typing (`DocumentController.addTaskAndEdit`). Replaces the
/// always-visible "new task…" field each section used to end with; Return
/// from an existing row (`insertSiblingAndEdit`) is the other way in.
private struct SectionAddTaskButton: View {
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

private struct OutlineSection: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let section: ListoSection
    /// Heading nesting depth (H1/H2/H3), independent of subtask depth.
    let depth: Int
    @State private var titleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .font(headingFont)
                .onAppear { titleText = section.title }

                SectionCountBadge(count: section.taskCount)

                SectionAddTaskButton { controller.addTaskAndEdit(toSectionID: section.id) }
                SectionDeleteButton { controller.deleteSection(sectionID: section.id) }

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)

            ForEach(section.displayTasks, id: \.id) { task in
                OutlineTaskRow(controller: controller, task: task, sectionDepth: depth + 1)
            }

            ForEach(section.subsections, id: \.id) { sub in
                OutlineSection(controller: controller, section: sub, depth: depth + 1)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        }
    }

    private var headingFont: Font {
        switch section.level {
        case 1: return settings.font(.title2, design: .monospaced, weight: .bold)
        case 2: return settings.font(.title3, design: .monospaced, weight: .bold)
        default: return settings.font(.body, design: .monospaced, weight: .bold)
        }
    }
}

/// A top-level task row within a section. Owns the single popover used for
/// editing this task's note — only a top-level task can have one (Listo's
/// tree is deliberately just task + subtask, and subtasks don't carry
/// notes), so `OutlineTaskNode` never attaches its own popover; it just
/// bubbles a `NoteEditTarget` up.
private struct OutlineTaskRow: View {
    @ObservedObject var controller: DocumentController
    let task: ListoTask
    let sectionDepth: Int
    @State private var noteEdit: NoteEditTarget?

    var body: some View {
        OutlineTaskNode(
            controller: controller,
            task: task,
            sectionDepth: sectionDepth,
            subtaskDepth: 0,
            allowMove: true,
            onEditNote: { noteEdit = $0 }
        )
        .draggable(task.id.uuidString)
        .popover(item: $noteEdit) { target in
            NoteEditorPopover(target: target) { newText in
                controller.setNote(taskID: target.id, note: newText.isEmpty ? nil : newText)
                noteEdit = nil
            }
        }
    }
}

/// One task or subtask row. `subtaskDepth` 0 is the top-level task, which
/// can carry a note and be indented into a subtask; `subtaskDepth` 1 is a
/// subtask, which cannot — both rules are enforced here (disabling the
/// action/hiding the note UI) and in `ListoEditor` (`maxSubtaskDepth`,
/// `setNote`). `sectionDepth` (heading nesting) is tracked separately so
/// the two kinds of indentation don't compound confusingly.
private struct OutlineTaskNode: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let task: ListoTask
    let sectionDepth: Int
    let subtaskDepth: Int
    let allowMove: Bool
    let onEditNote: (NoteEditTarget) -> Void
    @State private var text = ""
    @FocusState private var isRowFocused: Bool
    @FocusState private var isTextFieldFocused: Bool

    private static let maxDepth = ListoEditor.maxSubtaskDepth
    private var leadingPadding: CGFloat { CGFloat(sectionDepth) * 16 + CGFloat(subtaskDepth) * 14 }
    private var isSelected: Bool { controller.selectedTaskID == task.id }
    /// Whether the title is currently a live `TextField`. Click only
    /// selects the row (see `ownRow`'s doc comment below); this is what
    /// keeps a plain click from also dropping you into rename mode, which
    /// is what made right-click and Tab/⇧Tab-on-select unreliable before.
    ///
    /// Backed by the controller, not row-local `@State` — see `editingTaskID`
    /// doc comment. Return/Tab/⇧Tab all give this task a new id, and the
    /// `ForEach` below is keyed by id, so the row that replaces this one is
    /// a fresh view with fresh `@State`; only shared controller state
    /// survives that swap to keep the new row in edit mode too.
    private var isEditing: Bool { controller.editingTaskID == task.id }
    /// Only a top-level task can carry a note — Listo's tree is
    /// deliberately just task + subtask (see `ListoEditor.setNote`).
    private var canHaveNote: Bool { subtaskDepth == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ownRow

            ForEach(task.displaySubtasks, id: \.id) { sub in
                OutlineTaskNode(
                    controller: controller,
                    task: sub,
                    sectionDepth: sectionDepth,
                    subtaskDepth: subtaskDepth + 1,
                    allowMove: false,
                    onEditNote: onEditNote
                )
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
                if subtaskDepth > 0 {
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

                PriorityBadge(priority: task.priority, dimmed: task.state == .done)

                if canHaveNote, task.note == nil {
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
            // happens via the (shared, owned by OutlineTaskRow) popover,
            // opened by tapping the note itself. Top-level tasks only;
            // subtasks don't carry notes.
            if canHaveNote, let note = task.note, !note.isEmpty {
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
        .padding(.leading, leadingPadding)
        .padding(.vertical, 2)
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
            // Handles Return when the row is merely selected (not
            // text-editing) — the text field has its own handler for while
            // it's actively focused. Tab/Shift+Tab used to be handled here
            // too, but a `@FocusState` flip from inside a tap gesture (how
            // a row becomes "selected") doesn't reliably acquire real
            // AppKit focus, so this never reliably fired for those; the
            // Task menu (ListoApp.swift's `TaskCommands`, via
            // `@FocusedValue`) is the real, verified mechanism now.
            guard isRowFocused, !isEditing else { return .ignored }
            switch press.key {
            case .return:
                beginEditing()
                return .handled
            case .delete, .deleteForward:
                // A blank task/subtask (nothing typed yet) goes away on
                // Delete, same as while editing it below.
                guard press.phase == .down, task.text.isEmpty else { return .ignored }
                return controller.deleteEmpty(taskID: task.id, keepEditing: false) ? .handled : .ignored
            default:
                return .ignored
            }
        }
        .onAppear { text = task.text }
        // Not just `.onAppear`: two sibling tasks with the same text (most
        // commonly two blank ones — type into a blank task, hit Return, and
        // the fresh blank sibling `insertSiblingAndEdit` creates hashes to
        // the very id the just-renamed task had *before* it got its new
        // text — see StableID's per-parse, seed-ordinal disambiguation) can
        // land on the same content-derived id at different points in time.
        // SwiftUI then sees "the same row" and reuses this view's `@State
        // text` instead of mounting a fresh one, so the new row would start
        // out showing whatever was last typed here. Re-syncing whenever
        // *this row* becomes the edit target — not only when it first
        // appears — keeps the field correct regardless of view reuse.
        .onChange(of: isEditing) { _, editing in
            if editing { text = task.text }
        }
        .contextMenu {
            if canHaveNote {
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
            .disabled(subtaskDepth >= Self.maxDepth)
            Button {
                controller.outdent(taskID: task.id)
            } label: {
                Label(L("task.outdent", "Quitar indentación"), systemImage: "decrease.indent")
            }
            .disabled(subtaskDepth == 0)
            Button {
                controller.reorder(taskID: task.id, direction: -1)
            } label: {
                Label(L("task.moveUp", "Mover arriba"), systemImage: "arrow.up")
            }
            Button {
                controller.reorder(taskID: task.id, direction: 1)
            } label: {
                Label(L("task.moveDown", "Mover abajo"), systemImage: "arrow.down")
            }
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
            PriorityMenu(controller: controller, task: task)
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
    ///
    /// Return/Tab/⇧Tab are handled here, not via `TextField`'s `onCommit`
    /// (which only ever means "Return"): all three need to commit whatever
    /// was typed and then chain a second action — insert-next-sibling for
    /// Return, indent/outdent for Tab/⇧Tab — onto the *new* id a changed
    /// title gets, and `onKeyPress` is the one hook that can `return
    /// .handled` to stop Tab from also doing its default focus-navigation
    /// thing.
    @ViewBuilder
    private var titleField: some View {
        if isEditing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(subtaskDepth == 0 ? settings.font(.body) : settings.font(.caption))
                .focused($isTextFieldFocused)
                // Deferred a tick: setting `@FocusState` synchronously in
                // `.onAppear` — right as this exact view is being inserted
                // into the hierarchy by the same update that created it —
                // doesn't reliably win real AppKit first-responder status
                // (observed directly: keyboard input kept landing on
                // whichever field held focus *before* this row appeared).
                // Letting the view hierarchy settle for one run-loop turn
                // first makes the focus claim stick.
                .onAppear { DispatchQueue.main.async { isTextFieldFocused = true } }
                .onChange(of: isTextFieldFocused) { _, focused in
                    // Clicking away (another row, empty space, another
                    // control) commits and stops editing, no chained action.
                    if !focused { commitEditing() }
                }
                .onKeyPress { press in
                    switch press.key {
                    case .escape:
                        cancelEditing()
                        return .handled
                    case .return:
                        handleReturn()
                        return .handled
                    case .tab:
                        handleTab(outdent: press.modifiers.contains(.shift))
                        return .handled
                    case KeyEquivalent("\u{19}"):
                        // Shift+Tab: confirmed by direct diagnostic —
                        // AppKit reports it as the distinct "backtab"
                        // control character (0x19), not as `.tab` plus a
                        // shift modifier, so the `.tab` case above never
                        // matches it at all.
                        handleTab(outdent: true)
                        return .handled
                    case .delete, .deleteForward:
                        // Only on an already-empty field — otherwise Delete
                        // edits the text as usual. Fresh presses only, so
                        // holding Backspace to clear a title doesn't carry
                        // on through and delete the task too.
                        guard text.isEmpty, press.phase == .down else { return .ignored }
                        return controller.deleteEmpty(taskID: task.id, keepEditing: true) ? .handled : .ignored
                    case .upArrow:
                        handleVerticalNav(direction: -1)
                        return .handled
                    case .downArrow:
                        handleVerticalNav(direction: 1)
                        return .handled
                    default:
                        return .ignored
                    }
                }
        } else {
            Text(task.text)
                .font(subtaskDepth == 0 ? settings.font(.body) : settings.font(.caption))
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
        controller.editingTaskID = task.id
    }

    /// Commits the title if changed, without chaining any further action —
    /// used when editing ends because focus just left the field (a click
    /// elsewhere). Returns whether it renamed.
    ///
    /// Idempotency guard: ending edit mode (clearing `editingTaskID`) can
    /// itself cause `isTextFieldFocused` to flip to false as the field
    /// leaves the view tree, which re-fires the `onChange` above and would
    /// otherwise call this a second time — using this same (by-then-stale,
    /// already-renamed-away) `task.id` and blowing up with "task not
    /// found". Guarding on `isEditing` catches that: once `editingTaskID`
    /// has moved on (cleared here, or moved to a different row by
    /// `handleReturn`/`handleTab`), `isEditing` for *this* row is already
    /// false.
    @discardableResult
    private func commitEditing() -> Bool {
        guard isEditing else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let renamed = !trimmed.isEmpty && trimmed != task.text
        if renamed {
            controller.rename(taskID: task.id, newText: trimmed)
        } else {
            text = task.text
        }
        controller.editingTaskID = nil
        return renamed
    }

    private func cancelEditing() {
        guard isEditing else { return }
        text = task.text
        controller.editingTaskID = nil
    }

    /// Return: commit whatever was typed, then insert a new empty sibling
    /// (same level — a subtask begets a subtask) right after it and move
    /// edit focus straight there, so typing can continue without
    /// re-clicking. An empty title breaks the chain instead of piling up
    /// blank tasks — same as clicking away.
    private func handleReturn() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            cancelEditing()
            return
        }
        if trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        }
        controller.insertSiblingAndEdit(afterTaskID: controller.editingTaskID ?? task.id)
    }

    /// Tab/⇧Tab: commit whatever was typed, then indent/outdent — following
    /// onto whatever new id the commit gave the task, via `controller.
    /// editingTaskID` (`perform(followSelectionFrom:)` keeps it current) —
    /// and stay in edit mode on the row that results, instead of dropping
    /// back to merely-selected like a stray Tab keystroke used to.
    private func handleTab(outdent: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        }
        let anchorID = controller.editingTaskID ?? task.id
        if outdent {
            controller.outdent(taskID: anchorID)
        } else {
            controller.indent(taskID: anchorID)
        }
    }

    /// ↑/↓: commit whatever was typed, then move both selection and edit
    /// focus to the previous/next task — reads `controller.selectedTaskID`
    /// itself (already the post-rename id, via the same `perform(
    /// followSelectionFrom:)` following used everywhere else here) rather
    /// than needing an `anchorID` like `handleTab` does.
    private func handleVerticalNav(direction: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        }
        controller.selectAdjacent(direction: direction, keepEditing: true)
    }
}
