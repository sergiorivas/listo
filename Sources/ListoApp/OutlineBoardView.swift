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
                        .transition(Motion.sectionTransition)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    /// A task row is being dragged over this section (`dropDestination`).
    @State private var isDropTargeted = false

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

                SectionCountBadge(count: controller.filter.count(in: section))

                SectionAddTaskButton { controller.addTaskAndEdit(toSectionID: section.id) }
                SectionDeleteButton { controller.deleteSection(sectionID: section.id) }

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)

            ForEach(controller.filter.visible(section.displayTasks), id: \.id) { task in
                OutlineTaskRow(controller: controller, task: task, sectionDepth: depth + 1)
                    .transition(Motion.rowTransition)
            }

            ForEach(section.subsections, id: \.id) { sub in
                OutlineSection(controller: controller, section: sub, depth: depth + 1)
                    .transition(Motion.sectionTransition)
            }
        }
        .contentShape(Rectangle())
        .dropTargetHighlight(isDropTargeted, cornerRadius: 6)
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        } isTargeted: { isDropTargeted = $0 }
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
    private var isSelected: Bool { controller.isSelected(task.id) }
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
    private var editing: TitleEditing {
        TitleEditing(controller: controller, task: task, isEditing: isEditing, text: $text)
    }
    /// Only a top-level task can carry a note — Listo's tree is
    /// deliberately just task + subtask (see `ListoEditor.setNote`).
    private var canHaveNote: Bool { subtaskDepth == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ownRow

            ForEach(controller.filter.visibleSubtasks(of: task), id: \.id) { sub in
                OutlineTaskNode(
                    controller: controller,
                    task: sub,
                    sectionDepth: sectionDepth,
                    subtaskDepth: subtaskDepth + 1,
                    allowMove: false,
                    onEditNote: onEditNote
                )
                .transition(Motion.rowTransition)
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
                    TaskCheckboxIcon(isDone: task.state == .done)
                }
                .buttonStyle(.plain)

                titleField

                PriorityBadge(priority: task.priority, dimmed: task.state == .done)
                TaskMetaBadges(controller: controller, task: task)

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
                    .transition(.opacity)
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
                    .transition(Motion.rowTransition)
                    .onTapGesture {
                        controller.selectedTaskID = task.id
                        onEditNote(NoteEditTarget(id: task.id, initialText: note))
                    }
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .rowHighlight(isSelected: isSelected, isFlashing: controller.flashTaskID == task.id)
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
        .taskDragAndDrop(controller: controller, task: task, showsSubtasks: !controller.filter.visibleSubtasks(of: task).isEmpty)
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
            Button {
                controller.split(taskID: task.id)
            } label: {
                Label(L("task.split", "Dividir en tareas"), systemImage: "arrow.triangle.branch")
            }
            .disabled(task.subtasks.isEmpty)
            if controller.multiSelectedIDs.contains(task.id) {
                Button {
                    controller.group(taskID: task.id)
                } label: {
                    Label(L("task.group", "Agrupar en una tarea"), systemImage: "rectangle.stack")
                }
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
            DueMenu(controller: controller, task: task)
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
                    if !focused { editing.commit() }
                }
                .onKeyPress { press in
                    switch press.key {
                    case .escape:
                        editing.cancel()
                        return .handled
                    case .return:
                        editing.handleReturn()
                        return .handled
                    case .tab:
                        editing.handleTab(outdent: press.modifiers.contains(.shift))
                        return .handled
                    case KeyEquivalent("\u{19}"):
                        // Shift+Tab: confirmed by direct diagnostic —
                        // AppKit reports it as the distinct "backtab"
                        // control character (0x19), not as `.tab` plus a
                        // shift modifier, so the `.tab` case above never
                        // matches it at all.
                        editing.handleTab(outdent: true)
                        return .handled
                    case .delete, .deleteForward:
                        // Only on an already-empty field — otherwise Delete
                        // edits the text as usual. Fresh presses only, so
                        // holding Backspace to clear a title doesn't carry
                        // on through and delete the task too.
                        guard text.isEmpty, press.phase == .down else { return .ignored }
                        return controller.deleteEmpty(taskID: task.id, keepEditing: true) ? .handled : .ignored
                    case .upArrow:
                        editing.handleVerticalNav(direction: -1)
                        return .handled
                    case .downArrow:
                        editing.handleVerticalNav(direction: 1)
                        return .handled
                    default:
                        return .ignored
                    }
                }
        } else {
            Text(task.displayTitle)
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
}
