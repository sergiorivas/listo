import AppKit
import Foundation
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
    @Published private(set) var document: ListoDocument
    @Published var mode: EditMode = .app {
        didSet { modeChanged(from: oldValue) }
    }
    @Published var viewStyle: ViewStyle = .kanban
    /// The one selected task/subtask, à la Things — click any row to select
    /// it (independent of entering text-edit mode), then ⇥/⇧⇥ re-indents it
    /// without needing to first click into its text field. Shared here
    /// rather than per-view state so it survives switching between Kanban
    /// and Outline.
    @Published var selectedTaskID: UUID?
    /// The task whose title is currently a live text field, à la Workflowy —
    /// distinct from `selectedTaskID` (a row can be selected without being
    /// mid-edit). Kept here, not as row-local `@State`, because Return/Tab/
    /// ⇧Tab all give the edited task a new content/position-derived id
    /// (`StableID`): shared controller state can follow the id to the row
    /// that replaces this one, where per-row `@State` would just be
    /// discarded along with the old row, silently dropping out of edit mode.
    @Published var editingTaskID: UUID?
    @Published private(set) var logEvents: [LogEvent] = []
    @Published var errorMessage: String?

    private let fileDocument: ListoFileDocument
    private var editor: ListoEditor
    /// The text as of the last time it was interpreted — the last Modo
    /// Libre save (or mode switch), or the last Modo App action. The diff
    /// baseline for the next save.
    private var lastKnownText: String
    private var fileURL: URL?

    init(fileDocument: ListoFileDocument, fileURL: URL?) {
        self.fileDocument = fileDocument
        self.fileURL = fileURL
        let url = fileURL ?? DocumentController.scratchURL()
        self.editor = ListoEditor(fileURL: url, initialText: fileDocument.text, autoPersist: false)
        self.document = editor.document
        self.lastKnownText = fileDocument.text
        refreshLog()
        fileDocument.onWillSave = { [weak self] text in self?.handleSave(currentText: text) }
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
        perform { try $0.addTask(text: text, toSectionID: sectionID) }
    }

    /// Adds a new, empty top-level task at the end of `sectionID` and moves
    /// selection/edit focus onto it, ready to type — the section header's
    /// "+" button (next to its delete button, in both Kanban and Outline).
    /// Replaces the always-visible "new task…" field each section used to
    /// end with: adding a task is now either this, or Return from an
    /// existing row (`insertSiblingAndEdit`), never a separate text field
    /// competing for attention.
    func addTaskAndEdit(toSectionID sectionID: UUID) {
        guard perform({ try $0.addTask(text: "", toSectionID: sectionID) }) else { return }
        guard let newID = document.allSectionsRecursive.first(where: { $0.id == sectionID })?.tasks.last?.id else { return }
        selectedTaskID = newID
        editingTaskID = newID
    }

    func toggle(taskID: UUID) {
        guard perform({ try $0.toggle(taskID: taskID) }) else { return }
        playCompletionSoundIfNeeded(forTaskID: taskID)
        scheduleDoneMoveIfNeeded(forTaskID: taskID)
    }

    /// Plays `AppSettings.completionSoundEnabled`'s sound when the toggle
    /// just checked the task off (not when it reopened it). Only App Mode
    /// clicks reach here — a completion inferred from a Free Mode edit is
    /// not something the user just did, so it stays silent.
    private func playCompletionSoundIfNeeded(forTaskID taskID: UUID) {
        guard AppSettings.shared.completionSoundEnabled,
              document.allTasksRecursive.first(where: { $0.id == taskID })?.state == .done
        else { return }
        // Restart rather than let a quick second completion be swallowed by
        // the still-playing first one (`play()` is a no-op while playing).
        let sound = NSSound(named: "Glass")
        sound?.stop()
        sound?.play()
    }

    /// User-requested addition: checking off a top-level task, when the
    /// document has a section whose title contains "Done"/"Completed"/
    /// "Finished" (case-insensitive, any depth), bumps it to the end of
    /// that section after `AppSettings.doneMoveDelaySeconds` — a beat to
    /// see the checkmark land before the row jumps away, rather than an
    /// instant relocate. `0` disables the feature entirely.
    ///
    /// Everything is re-validated when the delay fires (not just captured
    /// up front): the task could have been unchecked, deleted, or reindented
    /// under a parent in the meantime, and the section could have been
    /// renamed or deleted — any of which just cancels the move rather than
    /// acting on stale state. A subtask is never moved (`moveTask` only
    /// supports top-level tasks — see the two-level model).
    private func scheduleDoneMoveIfNeeded(forTaskID taskID: UUID) {
        let delay = AppSettings.shared.doneMoveDelaySeconds
        guard delay > 0,
              let task = document.allTasksRecursive.first(where: { $0.id == taskID }),
              task.state == .done,
              document.location(of: task)?.parent == nil,
              let doneSection = Self.doneSection(in: document)
        else { return }
        let doneSectionID = doneSection.id

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let task = self.document.allTasksRecursive.first(where: { $0.id == taskID }),
                  task.state == .done,
                  self.document.location(of: task)?.parent == nil,
                  let liveDoneSection = self.document.allSectionsRecursive.first(where: { $0.id == doneSectionID }),
                  liveDoneSection.tasks.last?.id != taskID
            else { return }
            self.move(taskID: taskID, toSectionID: doneSectionID)
        }
    }

    /// First section (any nesting depth, document order) whose title
    /// contains one of the "done" keywords — a loose match, not an exact
    /// name, so "Done ✅" or "Completed tasks" both qualify.
    private static func doneSection(in document: ListoDocument) -> ListoSection? {
        let keywords = ["done", "completed", "finished"]
        return document.allSectionsRecursive.first { section in
            let title = section.title.lowercased()
            return keywords.contains { title.contains($0) }
        }
    }

    func rename(taskID: UUID, newText: String) {
        perform(followSelectionFrom: taskID) { try $0.renameTask(taskID: taskID, newText: newText) }
    }

    func renameSection(sectionID: UUID, newTitle: String) {
        perform { try $0.renameSection(sectionID: sectionID, newTitle: newTitle) }
    }

    func setNote(taskID: UUID, note: String?) {
        perform { try $0.setNote(taskID: taskID, note: note) }
    }

    func indent(taskID: UUID) {
        // First item / already at max nesting are expected boundary
        // conditions reachable from a plain Tab keystroke — no-op instead
        // of an intrusive error alert.
        perform(followSelectionFrom: taskID, silencing: { $0 == .noPrecedingSibling || $0 == .maxDepthReached }) {
            try $0.indentTask(taskID: taskID)
        }
    }

    func outdent(taskID: UUID) {
        perform(followSelectionFrom: taskID, silencing: { $0 == .alreadyTopLevel }) {
            try $0.outdentTask(taskID: taskID)
        }
    }

    /// ⌘↑ / ⌘↓ — `direction` is -1 (up) or +1 (down). First/last among its
    /// siblings is an expected boundary, so it's a silent no-op.
    func reorder(taskID: UUID, direction: Int) {
        perform(followSelectionFrom: taskID, silencing: { $0 == .noSiblingInDirection }) {
            try $0.reorderTask(taskID: taskID, direction: direction)
        }
    }

    func move(taskID: UUID, toSectionID sectionID: UUID) {
        perform(followSelectionFrom: taskID) { try $0.moveTask(taskID: taskID, toSectionID: sectionID) }
    }

    /// Inserts a new, empty sibling task right after `taskID` (same level —
    /// a subtask gets a subtask sibling) and moves selection/edit focus onto
    /// it, ready to type — the Return-to-keep-typing-the-next-item action.
    func insertSiblingAndEdit(afterTaskID taskID: UUID) {
        guard perform({ try $0.insertTaskAfter(taskID: taskID, text: "") }) else { return }
        if let newID = editor.lastActionTaskID {
            selectedTaskID = newID
            editingTaskID = newID
        }
    }

    func delete(taskID: UUID) {
        guard perform({ try $0.deleteTask(taskID: taskID) }) else { return }
        if selectedTaskID == taskID { selectedTaskID = nil }
        if editingTaskID == taskID { editingTaskID = nil }
    }

    /// Moves selection to the task immediately before (`direction: -1`) or
    /// after (`direction: +1`) the current selection — ↑/↓ arrow
    /// navigation. A no-op if nothing's selected or the move would go past
    /// either end, same as indent/outdent at their limits.
    ///
    /// Scoped to the current view style: Outline renders every section as
    /// one continuous vertical list, so navigation spans the whole
    /// document; Kanban renders each top-level section as its own
    /// side-by-side column, so navigation stays within the selected task's
    /// column — crossing into a different column on ↓ would jump somewhere
    /// spatially unrelated to where the arrow key points.
    ///
    /// `keepEditing`: pass `true` when called from a task's own title field
    /// (↑/↓ while typing) to move edit focus along with the selection, not
    /// just the selection itself — mirrors how Return/Tab already keep you
    /// typing across the task they create or re-indent.
    func selectAdjacent(direction: Int, keepEditing: Bool) {
        guard let currentID = selectedTaskID,
              let newID = adjacentTaskID(to: currentID, direction: direction) else { return }
        selectedTaskID = newID
        if keepEditing { editingTaskID = newID }
    }

    /// The task next to `taskID` in the current view style's navigation
    /// order (see `selectAdjacent`), or `nil` past either end.
    private func adjacentTaskID(to taskID: UUID, direction: Int) -> UUID? {
        let orderedIDs: [UUID]
        switch viewStyle {
        case .outline:
            orderedIDs = document.allTasksRecursive.map(\.id)
        case .kanban:
            guard let column = document.sections.first(where: { section in
                section.allTasksRecursive.contains { $0.id == taskID }
            }) else { return nil }
            orderedIDs = column.allTasksRecursive.map(\.id)
        }
        guard let idx = orderedIDs.firstIndex(of: taskID) else { return nil }
        let newIdx = idx + direction
        return orderedIDs.indices.contains(newIdx) ? orderedIDs[newIdx] : nil
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
    @discardableResult
    func deleteEmpty(taskID: UUID, keepEditing: Bool) -> Bool {
        guard let task = document.allTasksRecursive.first(where: { $0.id == taskID }),
              task.subtasks.isEmpty,
              task.note == nil
        else { return false }
        let neighborID = adjacentTaskID(to: taskID, direction: -1) ?? adjacentTaskID(to: taskID, direction: 1)
        guard perform({ try $0.deleteTask(taskID: taskID) }) else { return false }
        // Ids are content-derived, so a *following* neighbor can be re-id'd
        // by the delete (e.g. two blank tasks in a row) — only follow the
        // neighbor if it still resolves.
        let target = neighborID.flatMap { id in document.allTasksRecursive.contains { $0.id == id } ? id : nil }
        editingTaskID = keepEditing ? target : nil
        selectedTaskID = target
        return true
    }

    func deleteSection(sectionID: UUID) {
        perform { try $0.deleteSection(sectionID: sectionID) }
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
    /// - Returns: whether the action actually ran (`false` if it threw an
    ///   error that `silencing` swallowed, or an unsilenced one that was
    ///   surfaced via `errorMessage`) — callers that need `editor.
    ///   lastActionTaskID` afterward (e.g. a brand-new task with no prior id
    ///   to follow from) should check this first.
    @discardableResult
    private func perform(
        followSelectionFrom taskID: UUID? = nil,
        silencing: (ListoEditorError) -> Bool = { _ in false },
        _ action: (ListoEditor) throws -> LogEvent
    ) -> Bool {
        do {
            _ = try action(editor)
            document = editor.document
            lastKnownText = editor.currentText
            fileDocument.text = editor.currentText
            if let taskID, let newID = editor.lastActionTaskID {
                if selectedTaskID == taskID { selectedTaskID = newID }
                if editingTaskID == taskID { editingTaskID = newID }
            }
            refreshLog()
            // Persist immediately through Cocoa's own save pipeline — the
            // only writer of the real file (see the class doc comment) —
            // rather than waiting for its own autosave timer. Only once the
            // document already has a real path: on a brand-new, never-saved
            // document this would pop the "Save As" panel on every action.
            if fileURL != nil {
                NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            }
            return true
        } catch let error as ListoEditorError where silencing(error) {
            return false
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    private func refreshLog() {
        logEvents = (try? editor.readLog()) ?? []
    }

    func exportLogText() -> String {
        logEvents.map { event in
            (try? String(data: JSONEncoder().encode(event), encoding: .utf8) ?? "") ?? ""
        }.joined(separator: "\n")
    }

    var logFileURL: URL { editor.logWriter.logFileURL }
}
