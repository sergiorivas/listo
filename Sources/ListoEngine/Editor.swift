import Foundation

public enum ListoEditorError: Error, Equatable {
    case taskNotFound
    case sectionNotFound
    case noPrecedingSibling
    case maxDepthReached
    case alreadyTopLevel
    case subtaskNoteNotSupported
    case noSiblingInDirection
    case noSectionInDirection
    case noSubtasksToSplit
    /// Grouping needs two or more top-level tasks from one section.
    case cannotGroup
    /// A task to group has a note or subtasks, which a subtask can't hold.
    case groupedTaskHasContent
    /// Archiving found no finished top-level task to move.
    case nothingToArchive
    /// A drag-and-drop that makes no sense: onto itself or its own subtask,
    /// or a top-level task dropped between subtasks.
    case invalidMove
    /// Nesting a task under another needs it to have no note or subtasks of
    /// its own — a subtask can't hold either.
    case taskHasContent
}

/// Where a dragged task lands relative to the task it was dropped on.
public enum DropPlacement: Sendable {
    case before, after
    /// As the last subtask of the target.
    case asSubtask
}

/// Implements every "Modo App" action from spec §03. Each method performs a
/// single, minimal edit to the file's lines (never a full rewrite), persists
/// it, appends the resulting `LogEvent` straight to the log — no diffing, no
/// interpretation, since a button click already *is* a named action — and
/// re-parses to hand back a fresh, correctly-ranged `ListoDocument`.
///
/// Because every operation re-parses, `ListoTask`/`ListoSection` identity
/// does not survive across calls. Callers should resolve UI selections by
/// `UUID` against `document` immediately before invoking an operation, then
/// re-read `document` afterwards rather than holding onto stale references.
public final class ListoEditor {
    public internal(set) var document: ListoDocument
    public let fileURL: URL
    public let logWriter: LogWriter
    /// When `false`, operations update `document`/`currentText` in memory
    /// and log the event, but do not write the content file themselves —
    /// used when a host (like the SwiftUI `ReferenceFileDocument`) already
    /// owns persistence of the main file and only wants the engine's
    /// interpretation + log side effects. The log sidecar is always written
    /// immediately either way, since it is not the document SwiftUI manages.
    public var autoPersist: Bool
    /// The id of the task most recently touched by `renameTask`,
    /// `indentTask`, `outdentTask`, `reorderTask`, `moveTask`, or `insertTaskAfter` — re-
    /// resolved against `document` *after* that action's reparse. Ids are
    /// content/position derived (`StableID`), so any of those actions gives
    /// the task a new id (for `insertTaskAfter`, the newly created sibling's
    /// id); a caller tracking "the same" task across actions (e.g. a UI
    /// selection) should follow this rather than keep reusing the id it
    /// passed in, or a second action on what looks like the same row throws
    /// `taskNotFound`. `nil` after an action that doesn't change identity
    /// (`toggle`, `setNote`, ...) or that removes the task entirely.
    public internal(set) var lastActionTaskID: UUID?
    /// The day typed dates (`@tomorrow`, `@fri`) are resolved against when a
    /// title is written — injectable so tests don't depend on the clock.
    public var today: () -> TaskDueDate = { TaskDueDate(date: Date()) }
    var lines: [String]

    /// One Modo App action, as whole-file snapshots: what the text was
    /// before it, what it was after, and the event it logged. Snapshots (not
    /// per-action inverse operations) so undoing a delete brings back the
    /// task's note and subtasks exactly, and undoing a move/priority/toggle
    /// can't drift from what the forward action actually wrote.
    private struct HistoryEntry {
        let before: String
        let after: String
        let event: LogEvent
        /// Another file the action also wrote (the archive), restored along
        /// with the list on undo/redo.
        var sidecar: SidecarChange?
    }
    /// A second file's contents before and after an action; `nil` before
    /// means the action created it.
    struct SidecarChange {
        let url: URL
        let before: String?
        let after: String
    }
    /// Set by an action that writes a second file, consumed by `record(_:)`.
    var pendingSidecar: SidecarChange?
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    /// The text as of the last commit/undo/redo/external load — the "before"
    /// of the next action.
    private var baseText: String
    /// Set by `commit()`, consumed by `record(_:)` once the action's event
    /// exists.
    private var pendingChange: (before: String, after: String)?
    /// Inside `performBatch`: whether the batch has already filed its undo
    /// entry, so further actions merge into it instead of adding their own.
    private var isBatching = false
    private var batchHasEntry = false
    public static let maxUndoDepth = 100

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(fileURL: URL, initialText: String, autoPersist: Bool = true) {
        self.fileURL = fileURL
        self.logWriter = LogWriter(documentURL: fileURL)
        self.document = ListoParser.parse(initialText)
        self.lines = initialText.components(separatedBy: "\n")
        self.baseText = initialText
        self.autoPersist = autoPersist
    }

    public convenience init(fileURL: URL, autoPersist: Bool = true) throws {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        self.init(fileURL: fileURL, initialText: text, autoPersist: autoPersist)
    }

    public var currentText: String { lines.joined(separator: "\n") }

    /// Resyncs the in-memory buffer to text that changed out from under the
    /// editor — the host document's own text binding after a Modo Libre
    /// edit or save.
    ///
    /// If the text really changed, the undo/redo history is dropped: its
    /// snapshots predate the outside edit, and restoring one would silently
    /// throw that edit away.
    public func loadExternalText(_ text: String) {
        if text != baseText {
            undoStack.removeAll()
            redoStack.removeAll()
        }
        baseText = text
        lines = text.components(separatedBy: "\n")
        document = ListoParser.parse(text)
    }

    // MARK: - Undo / redo

    /// Reverts the most recent Modo App action (of any kind — a delete, a
    /// move, a priority change, a toggle, a rename, ...) by restoring the
    /// text from before it, and logs an `undone` event naming it. `nil` if
    /// there is nothing to undo. `lastActionTaskID` is not touched.
    @discardableResult
    public func undo() throws -> LogEvent? {
        guard let entry = undoStack.popLast() else { return nil }
        try restore(text: entry.before)
        if let sidecar = entry.sidecar { try restoreSidecar(sidecar.url, to: sidecar.before) }
        redoStack.append(entry)
        return try logWriter.append(historyEvent(.undone, for: entry.event))
    }

    /// Re-applies the action most recently undone, logging a `redone` event.
    /// `nil` if there is nothing to redo. Any new action clears the redo
    /// stack.
    @discardableResult
    public func redo() throws -> LogEvent? {
        guard let entry = redoStack.popLast() else { return nil }
        try restore(text: entry.after)
        if let sidecar = entry.sidecar { try restoreSidecar(sidecar.url, to: sidecar.after) }
        undoStack.append(entry)
        return try logWriter.append(historyEvent(.redone, for: entry.event))
    }

    private func historyEvent(_ kind: LogEvent.Kind, for original: LogEvent) -> LogEvent {
        LogEvent(
            file: fileURL.lastPathComponent,
            event: kind,
            taskID: original.taskID,
            sectionPath: original.sectionPath,
            text: original.text,
            source: .app,
            interpretedBy: .userAction,
            reverts: original.event
        )
    }

    private func restore(text: String) throws {
        lines = text.components(separatedBy: "\n")
        baseText = text
        try write(text)
    }

    /// Writes a sidecar file back to `text`, or removes it when the action
    /// being undone had created it.
    private func restoreSidecar(_ url: URL, to text: String?) throws {
        if let text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Appends the action's event to the log and files the action's
    /// snapshots under it in the undo history. Every public action ends with
    /// this instead of a bare `logWriter.append`.
    func record(_ event: LogEvent) throws -> LogEvent {
        if let change = pendingChange {
            if batchHasEntry, let first = undoStack.popLast() {
                // Same batch: one entry spanning the first action's "before"
                // to this one's "after", named after the first action.
                undoStack.append(HistoryEntry(before: first.before, after: change.after, event: first.event,
                                              sidecar: first.sidecar ?? pendingSidecar))
            } else {
                undoStack.append(HistoryEntry(before: change.before, after: change.after, event: event, sidecar: pendingSidecar))
                if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
                batchHasEntry = isBatching
            }
            redoStack.removeAll()
            pendingChange = nil
            pendingSidecar = nil
        }
        return try logWriter.append(event)
    }

    /// Runs several actions (one per selected task) as a single undo step:
    /// ⌘Z reverts all of them at once. Each action still logs its own event;
    /// the `undone`/`redone` event names the batch's first action.
    public func performBatch<T>(_ body: () throws -> T) rethrows -> T {
        isBatching = true
        batchHasEntry = false
        defer { isBatching = false; batchHasEntry = false }
        return try body()
    }

    // MARK: - Actions
    // (in Editor+Tasks.swift and Editor+Structure.swift)

    /// The sibling displayed right before (`direction: -1`) or after (`+1`)
    /// `taskID`, in the order `reorderTask` moves through; `nil` at either
    /// end or for an unknown task.
    public func displayNeighbor(of taskID: UUID, direction: Int) -> UUID? {
        guard let task = findTask(taskID), let (section, parent) = document.location(of: task) else { return nil }
        let siblings = parent?.displaySubtasks ?? section.displayTasks
        guard let idx = siblings.firstIndex(where: { $0.id == taskID }),
              siblings.indices.contains(idx + direction) else { return nil }
        return siblings[idx + direction].id
    }

    public func readLog() throws -> [LogEvent] {
        try logWriter.readAll()
    }

    // MARK: - Internals

    /// Writes the current buffer to disk and re-parses it into `document`.
    func commit() throws {
        let text = lines.joined(separator: "\n")
        pendingChange = (baseText, text)
        baseText = text
        try write(text)
    }

    func write(_ text: String) throws {
        if autoPersist {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        document = ListoParser.parse(text)
    }

    /// `commit()`, then records `lastActionTaskID` as whichever task ends
    /// up at `line` — the block's own line after `renameTask`/`indentTask`/
    /// `outdentTask`/`moveTask` moved or relabeled it, so those don't each
    /// have to pair `commit()` with a separate lookup themselves.
    func commit(trackingLine line: Int) throws {
        try commit()
        lastActionTaskID = taskAt(line: line)?.id
    }

    func findTask(_ id: UUID) -> ListoTask? {
        document.allTasksRecursive.first { $0.id == id } ?? document.looseTasks.first { $0.id == id }
    }

    /// After a mutation, section objects captured before the mutation are
    /// stale; re-resolve by title/level path from the *current* document so
    /// log events reflect the up-to-date tree.
    func refetch(_ section: ListoSection) -> ListoSection {
        document.allSectionsRecursive.first { $0.title == section.title && $0.level == section.level } ?? section
    }

    /// Whichever task now starts at `line`, post-reparse — how a fresh
    /// `LogEvent`'s `taskID` and `lastActionTaskID` (a task's new
    /// content/position-derived id after an action that moved or relabeled
    /// it) are both resolved. Named `taskAt`, not `task`, since most call
    /// sites already have a local `let task` in scope.
    func taskAt(line: Int) -> ListoTask? {
        document.allTasksRecursive.first { $0.lineRange?.lowerBound == line }
    }

    /// Contiguous line range spanning a task's own line, its note, and all of
    /// its subtasks (with their notes) — the block that must move together.
    func fullRange(of task: ListoTask) -> Range<Int> {
        guard let own = task.lineRange else { return 0..<0 }
        var end = own.upperBound + (task.note.map { $0.components(separatedBy: "\n").count } ?? 0)
        for sub in task.subtasks {
            end = max(end, fullRange(of: sub).upperBound)
        }
        return own.lowerBound..<end
    }

    /// A title as typed, with any date written in words fixed to the day
    /// it means now (see `TaskMetadata.resolvingRelativeDates`).
    func resolvingDates(_ text: String) -> String {
        TaskMetadata.resolvingRelativeDates(in: text, today: today())
    }

    func splitIndent(_ line: String) -> (indent: String, rest: Substring) {
        var s = Substring(line)
        var indent = ""
        while true {
            if s.hasPrefix("\t") {
                indent += "\t"
                s = s.dropFirst()
            } else if s.hasPrefix("  ") {
                indent += "  "
                s = s.dropFirst(2)
            } else {
                break
            }
        }
        return (indent, s)
    }
}
