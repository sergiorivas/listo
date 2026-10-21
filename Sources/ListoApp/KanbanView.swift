import SwiftUI
import AppKit
import ListoEngine

struct KanbanView: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var layout = KanbanLayoutStore.shared

    static let columnSpacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 16

    /// The width that fits every column with no scrolling — used by
    /// `ContentView` to size the window so it opens exactly as wide as it
    /// needs to be, no wider. Reflects each column's actual (possibly
    /// user-resized or collapsed) width rather than a single fixed
    /// constant, since columns are no longer all the same size.
    static func idealContentWidth(controller: DocumentController) -> CGFloat {
        let sections = controller.document.sections
        guard !sections.isEmpty else {
            return KanbanLayoutStore.defaultColumnWidth + horizontalPadding * 2
        }
        let widths = sections.map { section in
            KanbanLayoutStore.shared.isCollapsed(documentKey: controller.documentKey, sectionTitle: section.title)
                ? KanbanLayoutStore.collapsedColumnWidth
                : KanbanLayoutStore.shared.width(documentKey: controller.documentKey, sectionTitle: section.title)
        }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * columnSpacing + horizontalPadding * 2
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(controller.document.sections, id: \.id) { section in
                        KanbanColumn(
                            controller: controller,
                            section: section,
                            collapsedHeight: max(geometry.size.height - Self.horizontalPadding * 2, 0)
                        )
                            .transition(Motion.sectionTransition)
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

private struct KanbanColumn: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var layout = KanbanLayoutStore.shared
    let section: ListoSection
    /// Height of a collapsed column: the full height of the board, so every
    /// collapsed column is the same fixed strip whatever its title or count.
    let collapsedHeight: CGFloat
    @State private var titleText = ""
    /// Width while a drag on the resize handle is in progress — laid over
    /// the persisted width so the column tracks the mouse smoothly; only
    /// written back to `KanbanLayoutStore` (and to disk) once the drag ends.
    @State private var dragWidth: CGFloat?
    /// The column's own width when the current drag started — the base the
    /// live drag translation is added to, since `DragGesture.translation`
    /// is always relative to the drag's start, not the previous frame.
    @State private var dragBaseWidth: CGFloat?
    /// A task card is being dragged over this column (`dropDestination`).
    @State private var isDropTargeted = false

    private var documentKey: String { controller.documentKey }
    private var isCollapsed: Bool {
        layout.isCollapsed(documentKey: documentKey, sectionTitle: section.title)
    }
    private var storedWidth: CGFloat {
        layout.width(documentKey: documentKey, sectionTitle: section.title)
    }
    private var currentWidth: CGFloat {
        isCollapsed ? KanbanLayoutStore.collapsedColumnWidth : (dragWidth ?? storedWidth)
    }
    /// Position-based, not title-based: the first/last column in document
    /// order, regardless of what they're named — conventionally Today/Focus
    /// and Done respectively, but nothing here checks the actual title (see
    /// `AppSettings.firstSectionBackgroundColor`/`lastSectionBackgroundColor`).
    /// With exactly one section, first wins rather than layering both tints.
    private var columnBackground: Color {
        let sections = controller.document.sections
        if settings.firstSectionBackgroundEnabled, sections.first?.id == section.id {
            return settings.firstSectionBackgroundColor.opacity(0.18)
        }
        if settings.lastSectionBackgroundEnabled, sections.count > 1, sections.last?.id == section.id {
            return settings.lastSectionBackgroundColor.opacity(0.18)
        }
        return Color.gray.opacity(0.08)
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedStrip
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    taskList
                        .transition(.opacity)
                }
            }
        }
        .padding(10)
        .frame(width: currentWidth, height: isCollapsed ? collapsedHeight : nil, alignment: .top)
        .background(columnBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            // A collapsed column is a small target: any click on the strip
            // expands it, not just the chevron.
            if isCollapsed { toggleCollapsed() }
        }
        .overlay(alignment: .trailing) {
            if !isCollapsed {
                resizeHandle
            }
        }
        .dropTargetHighlight(isDropTargeted)
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 4) {
            collapseButton

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

            SectionCountBadge(count: controller.filter.count(in: section))

            Spacer(minLength: 0)

            SectionAddTaskButton { controller.addTaskAndEdit(toSectionID: section.id) }
            SectionDeleteButton { controller.deleteSection(sectionID: section.id) }
        }
    }

    /// The collapsed column: a fixed-width, full-board-height strip with the
    /// chevron and count on top and the title running down the side (like
    /// Trello/Jira). The old collapsed state squeezed the horizontal header
    /// into 44pt, so the title truncated and the badge wrapped, and the
    /// column's height depended on both. Here nothing can wrap: the title is
    /// rotated inside a frame of the remaining height and truncates at the end.
    private var collapsedStrip: some View {
        VStack(spacing: 8) {
            collapseButton
            SectionCountBadge(count: controller.filter.count(in: section))
                .fixedSize()
            GeometryReader { geo in
                let lineHeight = geo.size.width
                Text(section.title)
                    .font(settings.font(.headline, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: geo.size.height, height: lineHeight, alignment: .leading)
                    .rotationEffect(.degrees(90), anchor: .topLeading)
                    .offset(x: lineHeight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func toggleCollapsed() {
        withAnimation(Motion.snappy) {
            layout.setCollapsed(!isCollapsed, documentKey: documentKey, sectionTitle: section.title)
        }
    }

    private var collapseButton: some View {
        Button {
            toggleCollapsed()
        } label: {
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? L("column.expand", "Expandir columna") : L("column.collapse", "Colapsar columna"))
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.filter.visible(section.displayTasks), id: \.id) { task in
                    TaskChip(controller: controller, task: task)
                        .transition(Motion.rowTransition)
                }
                ForEach(section.subsections, id: \.id) { sub in
                    KanbanSubgroup(controller: controller, section: sub)
                        .transition(Motion.sectionTransition)
                }
            }
        }
    }

    /// A thin draggable strip on the column's trailing edge; dragging it
    /// resizes just this column (persisted per-document in
    /// `KanbanLayoutStore`, keyed by section title).
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        if dragBaseWidth == nil { dragBaseWidth = storedWidth }
                        let proposed = (dragBaseWidth ?? storedWidth) + value.translation.width
                        dragWidth = min(max(proposed, KanbanLayoutStore.minColumnWidth), KanbanLayoutStore.maxColumnWidth)
                    }
                    .onEnded { _ in
                        if let dragWidth {
                            layout.setWidth(dragWidth, documentKey: documentKey, sectionTitle: section.title)
                        }
                        dragWidth = nil
                        dragBaseWidth = nil
                    }
            )
    }
}

private struct KanbanSubgroup: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let section: ListoSection
    @State private var titleText = ""
    @State private var isDropTargeted = false

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

                SectionCountBadge(count: controller.filter.count(in: section))

                Spacer(minLength: 0)

                SectionAddTaskButton { controller.addTaskAndEdit(toSectionID: section.id) }
                SectionDeleteButton { controller.deleteSection(sectionID: section.id) }
            }
            ForEach(controller.filter.visible(section.displayTasks), id: \.id) { task in
                TaskChip(controller: controller, task: task)
                    .transition(Motion.rowTransition)
            }
            ForEach(section.subsections, id: \.id) { sub in
                KanbanSubgroup(controller: controller, section: sub)
                    .transition(Motion.sectionTransition)
            }
        }
        .dropTargetHighlight(isDropTargeted, cornerRadius: 6)
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let uuid = UUID(uuidString: idString) else { return false }
            controller.move(taskID: uuid, toSectionID: section.id)
            return true
        } isTargeted: { isDropTargeted = $0 }
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
    @FocusState private var isRowFocused: Bool
    @FocusState private var isTextFieldFocused: Bool

    private static let maxDepth = ListoEditor.maxSubtaskDepth
    private var isSelected: Bool { controller.isSelected(task.id) }
    /// Whether the title is currently a live `TextField`. Click only
    /// selects the row (see `ownRow`'s doc comment below); this is what
    /// keeps a plain click from also dropping you into rename mode, which
    /// is what made right-click and Tab/⇧Tab-on-select unreliable before.
    ///
    /// Backed by the controller, not row-local `@State` — see
    /// `DocumentController.editingTaskID`'s doc comment. Return/Tab/⇧Tab all
    /// give this task a new id, and the `ForEach`s above are keyed by id, so
    /// the row that replaces this one is a fresh view with fresh `@State`;
    /// only shared controller state survives that swap to keep the new row
    /// in edit mode too.
    private var isEditing: Bool { controller.editingTaskID == task.id }
    private var editing: TitleEditing {
        TitleEditing(controller: controller, task: task, isEditing: isEditing, text: $text)
    }
    /// Only a top-level task can carry a note — Listo's tree is
    /// deliberately just task + subtask (see `ListoEditor.setNote`).
    private var canHaveNote: Bool { depth == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: depth == 0 ? 4 : 2) {
            ownRow

            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(controller.filter.visibleSubtasks(of: task), id: \.id) { sub in
                        TaskRow(controller: controller, task: sub, depth: depth + 1, allowMove: false, onEditNote: onEditNote)
                            .transition(Motion.rowTransition)
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
            // happens via the (shared, owned by TaskChip) popover, opened
            // by tapping the note itself. Top-level tasks only; subtasks
            // don't carry notes.
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
        .padding(4)
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
            .disabled(depth >= Self.maxDepth)
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
    @ViewBuilder
    private var titleField: some View {
        if isEditing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(depth == 0 ? settings.font(.body) : settings.font(.caption))
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
                .font(depth == 0 ? settings.font(.body) : settings.font(.caption))
                .strikethrough(task.state == .done)
                .foregroundStyle(task.state == .done ? .secondary : .primary)
                // Two settings-driven behaviors when a title is wider than
                // the column: clip it to one line (`.truncate`), or let it
                // wrap and grow the row's (and so the column's) height
                // (`.wrap`) — see `KanbanTitleOverflow`.
                .lineLimit(settings.kanbanTitleOverflow == .truncate ? 1 : nil)
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
