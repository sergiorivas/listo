import SwiftUI
import ListoEngine

// Pieces shared by the Kanban and Outline task rows, which used to carry
// identical copies of each.

/// The checkbox button of a task row.
struct TaskCheckboxButton: View {
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TaskCheckboxIcon(isDone: isDone)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? L("task.reopen", "Reabrir tarea") : L("task.complete", "Marcar como hecha"))
    }
}

/// The "add note" icon. Only drawn while the row is hovered or selected —
/// at a constant 35% opacity on every row it was both faint and noise.
/// Layout is reserved either way so rows don't jump on hover.
struct AddNoteButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "note.text.badge.plus")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(Motion.quick, value: isVisible)
        .help(L("note.add.help", "Agregar nota"))
        .accessibilityLabel(L("note.add.help", "Agregar nota"))
    }
}

/// A task's note shown under its title, clamped to a few lines so one long
/// note can't make a card huge; "Show more" expands it in place. Tapping the
/// text opens the editor.
struct TaskNoteText: View {
    @ObservedObject private var settings = AppSettings.shared
    let note: String
    let onEdit: () -> Void
    @State private var isExpanded = false

    private static let collapsedLines = 3

    private var isLong: Bool {
        note.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines || note.count > 150
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note)
                .font(settings.font(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .textSelection(.enabled)
                .onTapGesture(perform: onEdit)
            if isLong {
                Button(isExpanded ? L("note.showLess", "Ver menos") : L("note.showMore", "Ver más")) {
                    withAnimation(Motion.snappy) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(settings.font(.caption))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.leading, 22)
        .transition(Motion.rowTransition)
    }
}

/// The right-click menu of a task row. `depth` 0 is a top-level task (can
/// carry a note, can't be outdented); `allowMove` is for top-level tasks.
struct TaskContextMenuContent: View {
    @ObservedObject var controller: DocumentController
    let task: ListoTask
    let depth: Int
    let allowMove: Bool
    let onEditNote: (NoteEditTarget) -> Void

    var body: some View {
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
        .disabled(depth >= ListoEditor.maxSubtaskDepth)
        Button {
            controller.outdent(taskID: task.id)
        } label: {
            Label(L("task.outdent", "Quitar indentación"), systemImage: "decrease.indent")
        }
        .disabled(depth == 0)
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
struct TaskTitleField: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let task: ListoTask
    let depth: Int
    /// `1` truncates a long title to one line, `nil` lets it wrap.
    let lineLimit: Int?
    let onBeginEditing: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    private var isEditing: Bool { controller.editingTaskID == task.id }
    private var editing: TitleEditing {
        TitleEditing(controller: controller, task: task, isEditing: isEditing)
    }
    private var font: Font { depth == 0 ? settings.font(.body) : settings.font(.caption) }

    var body: some View {
        if isEditing {
            TextField("", text: $controller.editingText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(font)
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
                        guard controller.editingText.isEmpty, press.phase == .down else { return .ignored }
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
                .font(font)
                .strikethrough(task.state == .done)
                .foregroundStyle(task.state == .done ? .secondary : .primary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A truncated title can still be read in full.
                .help(task.displayTitle)
                .onTapGesture(count: 2, perform: onBeginEditing)
        }
    }
}

/// "2/5" next to a parent task: how many of its subtasks are done.
struct SubtaskProgressBadge: View {
    @ObservedObject private var settings = AppSettings.shared
    let task: ListoTask

    var body: some View {
        let total = task.subtasks.count
        if total > 0 {
            let done = task.subtasks.filter { $0.state == .done }.count
            Text("\(done)/\(total)")
                .font(settings.font(.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(done == total ? Color.green : .secondary)
                .fixedSize()
                .help(String(format: L("subtask.progress", "%d de %d subtareas hechas"), done, total))
                .accessibilityLabel(String(format: L("subtask.progress", "%d de %d subtareas hechas"), done, total))
        }
    }
}

/// A thin vertical line down the left of a task's subtasks, tying them to
/// their parent.
struct SubtaskGuide: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1.5)
                .padding(.leading, -9)
        }
    }
}

extension View {
    func subtaskGuide() -> some View { modifier(SubtaskGuide()) }
}
