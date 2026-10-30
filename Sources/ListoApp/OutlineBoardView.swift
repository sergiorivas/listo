import SwiftUI
import ListoEngine

struct OutlineBoardView: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var selectionNamespace

    var body: some View {
        if controller.document.sections.isEmpty {
            EmptyBoardView { controller.addSection() }
        } else {
            list
                .selectionGlide(in: selectionNamespace)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(controller.document.sections, id: \.id) { section in
                    OutlineSection(controller: controller, section: section, depth: 0)
                        .transition(Motion.sectionTransition)
                }
                AddSectionButton { controller.addSection() }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OutlineSection: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var layout = OutlineLayoutStore.shared
    let section: ListoSection
    /// Heading nesting depth (H1/H2/H3), independent of subtask depth.
    let depth: Int
    @State private var isHeaderHovering = false
    /// A task row is being dragged over this section (`dropDestination`).
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                collapseButton

                SectionTitleField(controller: controller, section: section, font: headingFont)

                SectionCountBadge(count: controller.filter.count(in: section))

                SectionHeaderActions(
                    isVisible: isHeaderHovering,
                    onAdd: { controller.addTaskAndEdit(toSectionID: section.id) },
                    onDelete: { controller.deleteSection(sectionID: section.id) }
                )

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onHover { isHeaderHovering = $0 }
            .padding(.leading, CGFloat(depth) * 16)

            if !isCollapsed {
                // One container so folding/unfolding is a single
                // fade-and-unroll from under the heading, not every row
                // transitioning on its own.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.filter.visible(section.displayTasks), id: \.id) { task in
                        OutlineTaskRow(controller: controller, task: task, sectionDepth: depth + 1)
                            .transition(Motion.rowTransition)
                    }

                    ForEach(section.subsections, id: \.id) { sub in
                        OutlineSection(controller: controller, section: sub, depth: depth + 1)
                            .transition(Motion.sectionTransition)
                    }
                }
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

    private var isCollapsed: Bool {
        layout.isCollapsed(documentKey: controller.documentKey, sectionID: section.id)
    }

    private var collapseButton: some View {
        Button {
            controller.setOutlineSection(section.id, collapsed: !isCollapsed)
        } label: {
            Image(systemName: "chevron.down")
                .font(settings.font(.caption, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 14)
        }
        .buttonStyle(.pressable)
        .help(isCollapsed ? L("section.expand", "Expandir sección") : L("section.collapse", "Colapsar sección"))
        .accessibilityLabel(isCollapsed ? L("section.expand", "Expandir sección") : L("section.collapse", "Colapsar sección"))
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
    @State private var isHovering = false
    @FocusState private var isRowFocused: Bool

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
    /// Only a top-level task can carry a note — Listo's tree is
    /// deliberately just task + subtask (see `ListoEditor.setNote`).
    private var canHaveNote: Bool { subtaskDepth == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ownRow

            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
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
                // Guide line tying the subtasks to their parent.
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1.5)
                        .padding(.leading, leadingPadding + 6)
                }
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if subtaskDepth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                TaskCheckboxButton(isDone: task.state == .done) {
                    controller.selectedTaskID = task.id
                    isRowFocused = true
                    controller.toggle(taskID: task.id)
                }

                // Wraps instead of truncating: the outline has the whole
                // window width, so a long title shouldn't be cut off.
                TaskTitleField(
                    controller: controller,
                    task: task,
                    depth: subtaskDepth,
                    lineLimit: nil,
                    onBeginEditing: beginEditing
                )

                if subtaskDepth == 0 { SubtaskProgressBadge(task: task) }
                PriorityBadge(priority: task.priority, dimmed: task.state == .done)
                TaskMetaBadges(controller: controller, task: task)

                Spacer(minLength: 0)

                if canHaveNote, task.note == nil {
                    AddNoteButton(isVisible: isHovering || isSelected) {
                        controller.selectedTaskID = task.id
                        isRowFocused = true
                        onEditNote(NoteEditTarget(id: task.id, initialText: ""))
                    }
                }
            }

            // Note content shown directly, no click needed — editing still
            // happens via the (shared, owned by OutlineTaskRow) popover,
            // opened by tapping the note itself. Top-level tasks only;
            // subtasks don't carry notes.
            if canHaveNote, let note = task.note, !note.isEmpty {
                TaskNoteText(note: note) {
                    controller.selectedTaskID = task.id
                    onEditNote(NoteEditTarget(id: task.id, initialText: note))
                }
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .rowHighlight(
            isSelected: isSelected,
            isCursor: controller.selectedTaskID == task.id,
            isFlashing: controller.flashTaskID == task.id
        )
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
        .taskDragAndDrop(controller: controller, task: task, showsSubtasks: !controller.filter.visibleSubtasks(of: task).isEmpty)
        .contextMenu {
            TaskContextMenuContent(controller: controller, task: task, depth: subtaskDepth, allowMove: allowMove, onEditNote: onEditNote)
        }
    }

    private func beginEditing() {
        controller.selectedTaskID = task.id
        controller.editingTaskID = task.id
    }
}
