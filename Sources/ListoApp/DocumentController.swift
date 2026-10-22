import AppKit
import Foundation
import SwiftUI
import ListoEngine

/// Ties a `ListoFileDocument` to the `ListoEngine`: owns the parsed tree,
/// the Modo App action wrappers, and the Modo Libre diff-at-save pipeline
/// (spec §03/§05).
///
/// Modo Libre used to run a live FSEvents watcher that diffed on every disk
/// write (including Cocoa's own autosave), which made it possible for our
/// own in-flight write to be misread as an external change. That's gone:
/// free text is only interpreted once, right when the user saves (Cmd+S,
/// the toolbar Save button, or leaving Modo Libre) — see `handleSave`.
///
/// The `ListoEditor` is always constructed with `autoPersist: false` — the
/// `ListoFileDocument`/`DocumentGroup` machinery is the *only* writer of the
/// real file, in both modes. Modo App actions used to also have the engine
/// write the file directly (`autoPersist: true` whenever there was a real
/// URL), on top of `fileDocument.text` being updated and separately
/// autosaved by Cocoa — two uncoordinated writers racing for the same path.
/// Most of the time the extra write was harmless, but if Cocoa's autosave
/// captured an older snapshot and its (potentially slower, file-coordinated)
/// disk write landed *after* a newer direct write from the next action, the
/// newer edit was silently overwritten by the stale one — an intermittent,
/// hard-to-reproduce "autosave reverted my change." `perform` below now
/// asks Cocoa's own save pipeline to persist immediately after every action
/// instead (same call the Modo Libre toolbar Save button already uses), so
/// there is exactly one writer and immediate persistence, without the race.
@MainActor
final class DocumentController: ObservableObject {
    @Published internal(set) var document: ListoDocument
    @Published var mode: EditMode = .app {
        didSet { modeChanged(from: oldValue) }
    }
    @Published var viewStyle: ViewStyle = .kanban
    /// The one selected task/subtask, à la Things — click any row to select
    /// it (independent of entering text-edit mode), then ⇥/⇧⇥ re-indents it
    /// without needing to first click into its text field. Shared here
    /// rather than per-view state so it survives switching between Kanban
    /// and Outline.
    ///
    /// With a multi-selection this is the *cursor* — the end ⇧↑/⇧↓ moves.
    @Published var selectedTaskID: UUID? {
        didSet {
            // Any selection set from outside (a click, an action following a
            // renamed id) collapses a multi-selection; the code that builds
            // one sets `keepsMultiSelection` around its own assignment.
            guard !keepsMultiSelection else { return }
            if !multiSelectedIDs.isEmpty { multiSelectedIDs = [] }
            selectionAnchorID = nil
        }
    }
    /// Every selected task when ⇧↑/⇧↓ extended the selection past one row
    /// (cursor and anchor included); empty for a plain single selection.
    /// All of one level: tasks only, or subtasks only.
    @Published internal(set) var multiSelectedIDs: Set<UUID> = []
    var selectionAnchorID: UUID?
    var keepsMultiSelection = false
    /// The task whose title is currently a live text field, à la Workflowy —
    /// distinct from `selectedTaskID` (a row can be selected without being
    /// mid-edit). Kept here, not as row-local `@State`, because Return/Tab/
    /// ⇧Tab all give the edited task a new content/position-derived id
    /// (`StableID`): shared controller state can follow the id to the row
    /// that replaces this one, where per-row `@State` would just be
    /// discarded along with the old row, silently dropping out of edit mode.
    @Published var editingTaskID: UUID?
    /// A section whose title field should take focus (just created by
    /// `addSection`); the field clears it once it has claimed focus.
    @Published var focusSectionID: UUID?
    /// The search text and filter menu choices: they only decide which rows
    /// the views show (and ↑/↓ walks), never what is in the file.
    @Published var filter = TaskFilter()
    /// The task a drag started from — set by the row's drag source so drop
    /// targets can tell, while the pointer is still hovering, what would
    /// land where (the pasteboard payload only loads asynchronously on drop).
    var draggingTaskID: UUID?
    /// The task briefly highlighted after it jumps somewhere (moved to
    /// another section, re-indented, re-prioritised and so re-sorted), so
    /// the eye can follow it — see `flash(taskID:)` and `RowHighlight`.
    @Published private(set) var flashTaskID: UUID?
    private var flashGeneration = 0
    @Published private(set) var logEvents: [LogEvent] = []
    @Published var errorMessage: String?
    /// The file's text when it changed on disk while this window also has
    /// changes of its own — set until the user picks a side (see
    /// `checkForExternalChange`).
    @Published var pendingExternalText: String?

    let fileDocument: ListoFileDocument
    var editor: ListoEditor
    /// The text as of the last time it was interpreted — the last Modo
    /// Libre save (or mode switch), or the last Modo App action. The diff
    /// baseline for the next save.
    var lastKnownText: String
    /// What the file held when this window last read or saved it — the
    /// reference `checkForExternalChange` compares the disk against.
    var diskBaseline: String
    var fileURL: URL?

    init(fileDocument: ListoFileDocument, fileURL: URL?) {
        self.fileDocument = fileDocument
        self.fileURL = fileURL
        let url = fileURL ?? DocumentController.scratchURL()
        self.editor = ListoEditor(fileURL: url, initialText: fileDocument.text, autoPersist: false)
        self.document = editor.document
        self.lastKnownText = fileDocument.text
        self.diskBaseline = fileDocument.text
        refreshLog()
        fileDocument.onWillSave = { [weak self] text in
            self?.diskBaseline = text
            self?.handleSave(currentText: text)
        }
    }

    private static func scratchURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("untitled-\(UUID().uuidString).md")
    }

    /// Identifies this document for per-document UI state that isn't part
    /// of the file's own content (e.g. `KanbanLayoutStore`'s column widths).
    /// An unsaved scratch document gets a fresh, unpersisted key each time
    /// (its `scratchURL()` is random), which just means such state doesn't
    /// carry over until the document has a real path — acceptable since
    /// there's nothing meaningful to key it by before that.
    var documentKey: String { editor.fileURL.path }

    /// Call when the document's real on-disk URL becomes known (first save
    /// of a brand-new document) so the log sidecar starts targeting the
    /// real file.
    func bindToFileURL(_ url: URL) {
        guard fileURL != url else { return }
        fileURL = url
        editor = ListoEditor(fileURL: url, initialText: fileDocument.text, autoPersist: false)
        document = editor.document
        lastKnownText = fileDocument.text
        diskBaseline = fileDocument.text
        refreshLog()
    }

    // MARK: - Mode / view style

    private func modeChanged(from oldValue: EditMode) {
        guard mode != oldValue else { return }
        if mode == .freeEdit {
            lastKnownText = fileDocument.text
        } else {
            // Leaving Modo Libre: interpret whatever changed since the last
            // save (or since entering Modo Libre, if never saved) so the
            // structured views and the log are caught up, same as an
            // explicit save would do.
            handleSave(currentText: fileDocument.text)
            editor.loadExternalText(fileDocument.text)
            document = editor.document
        }
    }

    // MARK: - Modo Libre: diff at save time

    /// The only place Modo Libre's free text gets interpreted: called via
    /// `ListoFileDocument.onWillSave` right before the document is
    /// persisted (Cmd+S, the toolbar Save button, or macOS autosave), and
    /// also when leaving Modo Libre. Computes "what changed since last
    /// time" once and logs it — no live watcher, no per-keystroke debounce.
    private func handleSave(currentText: String) {
        guard mode == .freeEdit else { return }
        let oldText = lastKnownText
        guard oldText != currentText else { return }
        lastKnownText = currentText
        editor.loadExternalText(currentText)
        document = editor.document

        let outcome = ListoDiffer.diff(fileName: editor.fileURL.lastPathComponent, oldText: oldText, newText: currentText)
        switch outcome {
        case .resolved(let events):
            for event in events { _ = try? editor.logWriter.append(event) }
            refreshLog()
        case .ambiguous(let guess, let old, let new):
            Task {
                do {
                    let client = Self.makeLLMClient()
                    let events = try await client.interpretDiff(fileName: editor.fileURL.lastPathComponent, oldText: old, newText: new)
                    await MainActor.run {
                        for event in events { _ = try? self.editor.logWriter.append(event) }
                        self.refreshLog()
                    }
                } catch {
                    await MainActor.run {
                        // No LLM available, or the call failed — log the
                        // fallback instead of guessing wrong or silently
                        // dropping the change.
                        let reason = Self.unresolvedReason(for: error)
                        _ = try? self.editor.logWriter.append(ListoDiffer.unresolvedChangeEvent(fileName: self.editor.fileURL.lastPathComponent, reason: reason))
                        _ = guess
                        self.refreshLog()
                    }
                }
            }
        }
    }

    /// Turns whatever `LLMClient.interpretDiff` threw into the short reason
    /// shown by `LogFormatter.describe(.unresolved)` — distinguishing "no
    /// key configured" from an actual failed call (rate limit, network,
    /// bad response) so the latter doesn't misleadingly read as the former.
    private static func unresolvedReason(for error: Error) -> String {
        switch error {
        case LLMError.unavailable:
            return "no API key configured"
        case LLMError.badResponse(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "LLM request failed" : "LLM request failed: \(trimmed.prefix(200))"
        default:
            return "LLM request failed: \(error.localizedDescription)"
        }
    }

    private static func makeLLMClient() -> LLMClient {
        switch AppSettings.shared.llmProvider {
        case .anthropic:
            return AnthropicLLMClient() ?? UnavailableLLMClient()
        case .openRouter:
            return OpenRouterLLMClient() ?? UnavailableLLMClient()
        }
    }

    // MARK: - Modo App actions

    func addTask(text: String, toSectionID sectionID: UUID) {
        perform(animation: Motion.snappy) { try $0.addTask(text: text, toSectionID: sectionID) }
    }

    /// Adds a new, empty top-level task at the end of `sectionID` and moves
    /// selection/edit focus onto it, ready to type — the section header's
    /// "+" button (next to its delete button, in both Kanban and Outline).
    /// Replaces the always-visible "new task…" field each section used to
    /// end with: adding a task is now either this, or Return from an
    /// existing row (`insertSiblingAndEdit`), never a separate text field
    /// competing for attention.
    func addTaskAndEdit(toSectionID sectionID: UUID) {
        guard perform(animation: Motion.snappy, { try $0.addTask(text: "", toSectionID: sectionID) }) else { return }
        guard let newID = document.allSectionsRecursive.first(where: { $0.id == sectionID })?.tasks.last?.id else { return }
        selectedTaskID = newID
        editingTaskID = newID
    }

    /// ⌘N: a new task at the end of the first top-level section (the first
    /// Kanban column), ready to type.
    func addTaskToFirstSectionAndEdit() {
        guard let first = document.sections.first else { return }
        addTaskAndEdit(toSectionID: first.id)
    }

    func toggle(taskID: UUID) {
        guard perform(animation: Motion.quick, { try $0.toggle(taskID: taskID) }) else { return }
        SoundPlayer.playCompletionIfNeeded(document: document, taskID: taskID)
        scheduleDoneMoveIfNeeded(forTaskID: taskID)
    }


    func rename(taskID: UUID, newText: String) {
        perform(followSelectionFrom: taskID) { try $0.renameTask(taskID: taskID, newText: newText) }
    }

    func setPriority(taskID: UUID, priority: TaskPriority) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            performBatch(ids) { try $0.setPriority(taskID: $1, priority: priority) }
            return
        }
        // The id is stable (the marker isn't part of it), so the row glides
        // to its new sorted spot; flash it since that jump can be long.
        guard perform(animation: Motion.snappy, { try $0.setPriority(taskID: taskID, priority: priority) }) else { return }
        flash(taskID: taskID)
    }

    /// Appends a new column/section and puts its title into editing.
    func addSection() {
        guard perform(animation: Motion.snappy, { try $0.addSection(title: L("section.new", "Nueva columna")) }) else { return }
        focusSectionID = document.sections.last?.id
    }

    func renameSection(sectionID: UUID, newTitle: String) {
        perform { try $0.renameSection(sectionID: sectionID, newTitle: newTitle) }
    }

    func setNote(taskID: UUID, note: String?) {
        perform(animation: Motion.snappy) { try $0.setNote(taskID: taskID, note: note) }
    }

    func indent(taskID: UUID) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            performBatch(ids, follow: true, silencing: { $0 == .noPrecedingSibling || $0 == .maxDepthReached }) {
                try $0.indentTask(taskID: $1)
            }
            return
        }
        // First item / already at max nesting are expected boundary
        // conditions reachable from a plain Tab keystroke — no-op instead
        // of an intrusive error alert.
        perform(animation: Motion.snappy, flash: true, followSelectionFrom: taskID, silencing: { $0 == .noPrecedingSibling || $0 == .maxDepthReached }) {
            try $0.indentTask(taskID: taskID)
        }
    }

    func outdent(taskID: UUID) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            // Last first: each one lands right after its parent's block, so
            // going bottom-up keeps their relative order.
            performBatch(ids.reversed(), follow: true, silencing: { $0 == .alreadyTopLevel }) {
                try $0.outdentTask(taskID: $1)
            }
            return
        }
        perform(animation: Motion.snappy, flash: true, followSelectionFrom: taskID, silencing: { $0 == .alreadyTopLevel }) {
            try $0.outdentTask(taskID: taskID, absorbingFollowingSiblings: AppSettings.shared.outdentAbsorbsSiblings)
        }
    }

    /// ⌘↑ / ⌘↓ — `direction` is -1 (up) or +1 (down). First/last among its
    /// siblings is an expected boundary, so it's a silent no-op.
    func reorder(taskID: UUID, direction: Int) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            // Leading edge first, and a task whose neighbour is a selected
            // one that couldn't move stays put too — so the block moves as
            // one and stops at the edge instead of shuffling through itself.
            let selected = Set(ids)
            performBatch(direction < 0 ? ids : ids.reversed(), follow: true, silencing: { $0 == .noSiblingInDirection }) { editor, id in
                if let neighbor = editor.displayNeighbor(of: id, direction: direction), selected.contains(neighbor) { return }
                try editor.reorderTask(taskID: id, direction: direction)
            }
            return
        }
        perform(animation: Motion.snappy, followSelectionFrom: taskID, silencing: { $0 == .noSiblingInDirection }) {
            try $0.reorderTask(taskID: taskID, direction: direction)
        }
    }

    /// ⌘T — replaces a task with one task per subtask. A task without
    /// subtasks is an expected no-op.
    func split(taskID: UUID) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            performBatch(ids.reversed(), silencing: { $0 == .noSubtasksToSplit || $0 == .taskNotFound }) { try $0.splitTask(taskID: $1) }
            return
        }
        perform(animation: Motion.snappy, followSelectionFrom: taskID, silencing: { $0 == .noSubtasksToSplit }) {
            try $0.splitTask(taskID: taskID)
        }
    }

    /// ⌘G — merges the multi-selected top-level tasks into one task with
    /// them as subtasks. The group is selected afterwards, and put straight
    /// into title editing when it got the placeholder name so it can be
    /// renamed right away.
    func group(taskID: UUID) {
        let ids = targets(for: taskID)
        guard ids.count > 1 else { return }
        guard perform(animation: Motion.snappy, flash: true, followSelectionFrom: taskID, { try $0.groupTasks(taskIDs: ids) }),
              let groupID = editor.lastActionTaskID else { return }
        keepsMultiSelection = true
        multiSelectedIDs = []
        selectedTaskID = groupID
        keepsMultiSelection = false
        selectionAnchorID = nil
        if document.allTasksRecursive.first(where: { $0.id == groupID })?.text == ListoEditor.defaultGroupName {
            editingTaskID = groupID
        }
    }

    /// ⌘← / ⌘→ in Kanban — `direction` is -1 (previous column) or +1 (next).
    /// First/last column, or a subtask, is an expected boundary: silent no-op.
    func moveToAdjacentSection(taskID: UUID, direction: Int) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            performBatch(ids, follow: true, silencing: { $0 == .noSectionInDirection }) {
                try $0.moveTaskToAdjacentSection(taskID: $1, direction: direction)
            }
            return
        }
        perform(followSelectionFrom: taskID, silencing: { $0 == .noSectionInDirection }) {
            try $0.moveTaskToAdjacentSection(taskID: taskID, direction: direction)
        }
    }

    /// Drag-and-drop onto a task: next to it, or as its last subtask. A drop
    /// the engine refuses (`DropRule` already filters these) is a silent
    /// no-op.
    func drop(taskID: UUID, onto targetID: UUID, placement: DropPlacement) {
        perform(animation: Motion.snappy, flash: true, followSelectionFrom: taskID, silencing: { $0 == .invalidMove || $0 == .taskHasContent }) {
            try $0.moveTask(taskID: taskID, relativeTo: targetID, placement: placement)
        }
    }

    func move(taskID: UUID, toSectionID sectionID: UUID) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            performBatch(ids, follow: true) { try $0.moveTask(taskID: $1, toSectionID: sectionID) }
            return
        }
        perform(animation: Motion.snappy, flash: true, followSelectionFrom: taskID) { try $0.moveTask(taskID: taskID, toSectionID: sectionID) }
    }

    /// Inserts a new, empty sibling task right after `taskID` (same level —
    /// a subtask gets a subtask sibling) and moves selection/edit focus onto
    /// it, ready to type — the Return-to-keep-typing-the-next-item action.
    func insertSiblingAndEdit(afterTaskID taskID: UUID) {
        guard perform(animation: Motion.snappy, { try $0.insertTaskAfter(taskID: taskID, text: "") }) else { return }
        if let newID = editor.lastActionTaskID {
            selectedTaskID = newID
            editingTaskID = newID
        }
    }

    func delete(taskID: UUID) {
        let ids = targets(for: taskID)
        if ids.count > 1 {
            if performBatch(ids, silencing: { $0 == .taskNotFound }, { try $0.deleteTask(taskID: $1) }) { SoundPlayer.playDeleteIfNeeded() }
            return
        }
        guard perform(animation: Motion.snappy, { try $0.deleteTask(taskID: taskID) }) else { return }
        if selectedTaskID == taskID { selectedTaskID = nil }
        if editingTaskID == taskID { editingTaskID = nil }
        SoundPlayer.playDeleteIfNeeded()
    }


    /// No blank tasks survive losing focus: a task/subtask may be empty
    /// while it is being edited, but is deleted as soon as editing moves
    /// elsewhere. Unlike `deleteEmpty` (an explicit Backspace) this leaves
    /// selection and edit focus where the user put them, and — same guard —
    /// never removes a task that has a note or subtasks.
    @discardableResult
    func discardIfBlank(taskID: UUID) -> Bool {
        guard let task = document.allTasksRecursive.first(where: { $0.id == taskID }),
              task.text.trimmingCharacters(in: .whitespaces).isEmpty,
              task.subtasks.isEmpty,
              task.note == nil
        else { return false }
        guard perform(animation: Motion.snappy, { try $0.deleteTask(taskID: taskID) }) else { return false }
        if selectedTaskID == taskID { selectedTaskID = nil }
        if editingTaskID == taskID { editingTaskID = nil }
        return true
    }

    /// Delete/Backspace on a task or subtask whose title is empty removes it
    /// — the caller has already checked the title (the live field while
    /// editing, the task's own text when merely selected). Selection (and
    /// edit focus, if `keepEditing`) moves to the task before it — or the
    /// one after, if it was first — so a run of Backspaces keeps working
    /// through a list the way Return keeps adding to one.
    ///
    /// Refuses (returns `false`) when the task still carries a note or
    /// subtasks: `deleteTask` removes the whole block, so an empty title
    /// isn't enough evidence the user means to drop that content too.
    func deleteEmpty(taskID: UUID, keepEditing: Bool) -> Bool {
        guard let task = document.allTasksRecursive.first(where: { $0.id == taskID }),
              task.subtasks.isEmpty,
              task.note == nil
        else { return false }
        let neighborID = adjacentTaskID(to: taskID, direction: -1) ?? adjacentTaskID(to: taskID, direction: 1)
        guard perform(animation: Motion.snappy, { try $0.deleteTask(taskID: taskID) }) else { return false }
        // Ids are content-derived, so a *following* neighbor can be re-id'd
        // by the delete (e.g. two blank tasks in a row) — only follow the
        // neighbor if it still resolves.
        let target = neighborID.flatMap { id in document.allTasksRecursive.contains { $0.id == id } ? id : nil }
        editingTaskID = keepEditing ? target : nil
        selectedTaskID = target
        SoundPlayer.playDeleteIfNeeded()
        return true
    }

    func deleteSection(sectionID: UUID) {
        perform(animation: Motion.snappy) { try $0.deleteSection(sectionID: sectionID) }
    }

    // MARK: - Undo / redo

    var canUndo: Bool { editor.canUndo }
    var canRedo: Bool { editor.canRedo }

    /// ⌘Z — reverts the last Modo App action (see `ListoEditor.undo`). Free
    /// Mode has its own text undo, so this is App Mode only.
    func undo() { stepHistory { try $0.undo() } }

    /// ⇧⌘Z — re-applies the last undone action.
    func redo() { stepHistory { try $0.redo() } }

    private func stepHistory(_ step: (ListoEditor) throws -> LogEvent?) {
        guard mode == .app else { return }
        do {
            guard let event = try step(editor) else { return }
            syncDocumentText()
            withAnimation(Motion.snappy) {
                document = editor.document
                // Ids are content-derived: a selection/edit target that the
                // step removed (undoing a create, redoing a delete) is gone.
                let live = Set(document.allTasksRecursive.map(\.id))
                if let id = selectedTaskID, !live.contains(id) { selectedTaskID = nil }
                if let id = editingTaskID, !live.contains(id) { editingTaskID = nil }
                // Point at what the step brought back or moved, when it can
                // be found (log `taskID`s are the derived short ids).
                if let touched = document.allTasksRecursive.first(where: { $0.shortID == event.taskID }) {
                    selectedTaskID = touched.id
                    flash(taskID: touched.id)
                }
            }
            refreshLog()
            saveIfPossible()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// - Parameter followSelectionFrom: pass the id the action was invoked
    ///   on for `renameTask`/`indentTask`/`outdentTask`/`moveTask` — those
    ///   give the task a new content/position-derived id (`StableID`), so
    ///   `selectedTaskID`/`editingTaskID` are moved to `editor.
    ///   lastActionTaskID` afterward, whichever of the two currently equal
    ///   it. Otherwise a second action on what still looks like the same
    ///   selected/edited row (another rename, an outdent right after an
    ///   indent, Return-to-indent while typing, ...) would reuse the
    ///   now-stale id and throw `taskNotFound`, or leave `editingTaskID`
    ///   pointing at a row that no longer exists — silently dropping out of
    ///   edit mode.
    /// - Parameter animation: how the resulting tree change animates; `nil`
    ///   (the default) applies it instantly. Deliberately opt-in per action
    ///   rather than an always-on animation on the lists: a rename gives the
    ///   row a new content-derived id (`StableID`), which SwiftUI sees as
    ///   "row removed, row inserted" — animating that would fade the row
    ///   out and back in on every committed edit.
    /// - Parameter flash: after the action, briefly highlight the task it
    ///   acted on (needs `followSelectionFrom`, for the id to look up).
    /// - Returns: whether the action actually ran (`false` if it threw an
    ///   error that `silencing` swallowed, or an unsilenced one that was
    ///   surfaced via `errorMessage`) — callers that need `editor.
    ///   lastActionTaskID` afterward (e.g. a brand-new task with no prior id
    ///   to follow from) should check this first.
    @discardableResult
    func perform(
        animation: Animation? = nil,
        flash: Bool = false,
        followSelectionFrom taskID: UUID? = nil,
        silencing: (ListoEditorError) -> Bool = { _ in false },
        _ action: (ListoEditor) throws -> LogEvent
    ) -> Bool {
        do {
            _ = try action(editor)
            syncDocumentText()
            let apply = {
                self.document = self.editor.document
                if let taskID, let newID = self.editor.lastActionTaskID {
                    if self.selectedTaskID == taskID { self.selectedTaskID = newID }
                    if self.editingTaskID == taskID { self.editingTaskID = newID }
                }
            }
            if let animation {
                withAnimation(animation, apply)
            } else {
                apply()
            }
            if flash, taskID != nil, let newID = editor.lastActionTaskID {
                self.flash(taskID: newID)
            }
            refreshLog()
            saveIfPossible()
            return true
        } catch let error as ListoEditorError where silencing(error) {
            return false
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    func syncDocumentText() {
        lastKnownText = editor.currentText
        fileDocument.text = editor.currentText
    }

    /// Persist immediately through Cocoa's own save pipeline — the only
    /// writer of the real file (see the class doc comment) — rather than
    /// waiting for its own autosave timer. Only once the document already has
    /// a real path: on a brand-new, never-saved document this would pop the
    /// "Save As" panel on every action.
    func saveIfPossible() {
        if fileURL != nil {
            NSApp?.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        }
    }

    /// Highlights `taskID`'s row for a moment (`RowHighlight`), fading out
    /// after — a later flash cancels the earlier one's fade-out.
    func flash(taskID: UUID) {
        flashGeneration += 1
        let generation = flashGeneration
        withAnimation(Motion.quick) { flashTaskID = taskID }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            withAnimation(Motion.flashFade) { self.flashTaskID = nil }
        }
    }

    func refreshLog() {
        logEvents = (try? editor.readLog()) ?? []
    }

    func exportLogText() -> String {
        logEvents.map { event in
            (try? String(data: JSONEncoder().encode(event), encoding: .utf8) ?? "") ?? ""
        }.joined(separator: "\n")
    }

    var logFileURL: URL { editor.logWriter.logFileURL }
}
