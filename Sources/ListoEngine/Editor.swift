import Foundation

public enum ListoEditorError: Error, Equatable {
    case taskNotFound
    case sectionNotFound
    case noPrecedingSibling
    case maxDepthReached
    case alreadyTopLevel
    case subtaskNoteNotSupported
    case noSiblingInDirection
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
    public private(set) var document: ListoDocument
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
    public private(set) var lastActionTaskID: UUID?
    private var lines: [String]

    public init(fileURL: URL, initialText: String, autoPersist: Bool = true) {
        self.fileURL = fileURL
        self.logWriter = LogWriter(documentURL: fileURL)
        self.document = ListoParser.parse(initialText)
        self.lines = initialText.components(separatedBy: "\n")
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
    public func loadExternalText(_ text: String) {
        lines = text.components(separatedBy: "\n")
        document = ListoParser.parse(text)
    }

    // MARK: - Actions

    @discardableResult
    public func addTask(text: String, toSectionID sectionID: UUID) throws -> LogEvent {
        guard let section = document.allSectionsRecursive.first(where: { $0.id == sectionID }) else {
            throw ListoEditorError.sectionNotFound
        }
        let insertionIndex = section.tasks.last.map { fullRange(of: $0).upperBound }
            ?? (section.lineRange?.lowerBound ?? lines.count - 1) + 1
        lines.insert("- [ ] \(text)", at: insertionIndex)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .created,
            taskID: taskAt(line: insertionIndex)?.shortID ?? "t_????",
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: text,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    @discardableResult
    public func toggle(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        let line = task.lineRange!.lowerBound
        let (indent, rest) = splitIndent(lines[line])
        let newState: TaskState = task.state == .done ? .open : .done
        let box = newState == .done ? "[x]" : "[ ]"
        let logText = document.logText(for: task)
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }
        // Only the checkbox changes; everything after it (including any
        // priority marker) is kept exactly as written.
        lines[line] = indent + "- \(box)" + rest.dropFirst(5)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: newState == .done ? .completed : .reopened,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    @discardableResult
    public func renameTask(taskID: UUID, newText: String) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        let line = task.lineRange!.lowerBound
        let (indent, _) = splitIndent(lines[line])
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }
        // The views show (and edit) the title without its priority marker,
        // so a plain rename must keep the priority; typing a marker into
        // the new text (`Buy milk !!`) sets it instead.
        let parsed = TaskPriority.split(newText)
        let hasTypedMarker = parsed.priority != .none
        let newTitle = hasTypedMarker ? parsed.text : newText
        let priority = hasTypedMarker ? parsed.priority : task.priority
        let logText = document.logText(for: task, text: newTitle)
        lines[line] = ListoSerializer.taskLine(indent: indent, state: task.state, text: newTitle, priority: priority)
        try commit(trackingLine: line)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .edited,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Sets (or, with `.none`, clears) a task's or subtask's priority by
    /// rewriting the trailing `!`/`!!`/`!!!` marker on its line. The task
    /// keeps its position in the file — priority only changes where it is
    /// *displayed* (`ListoTask.sortedByPriority`) — and its id, since ids
    /// are derived from the title, not the priority.
    ///
    /// Logged with the marker appended to `text` when set, or bare when
    /// cleared (`LogFormatter` tells the two apart by that trailing
    /// marker, which a task's own text can never end with — it is parsed
    /// off).
    @discardableResult
    public func setPriority(taskID: UUID, priority: TaskPriority) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        let line = task.lineRange!.lowerBound
        let (indent, _) = splitIndent(lines[line])
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }
        let logText = document.logText(for: task)
        lines[line] = ListoSerializer.taskLine(indent: indent, state: task.state, text: task.text, priority: priority)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .priorityChanged,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: priority == .none ? logText : "\(logText) \(priority.marker)",
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Renames a section's heading (the Kanban column title / Outline
    /// heading text), preserving its level (`#`/`##`/`###`).
    @discardableResult
    public func renameSection(sectionID: UUID, newTitle: String) throws -> LogEvent {
        guard let section = document.allSectionsRecursive.first(where: { $0.id == sectionID }),
              let line = section.lineRange?.lowerBound else {
            throw ListoEditorError.sectionNotFound
        }
        let oldPath = document.path(to: section) ?? [section.title]
        lines[line] = String(repeating: "#", count: section.level) + " " + newTitle
        try commit()

        var newPath = oldPath
        newPath[newPath.count - 1] = newTitle

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .edited,
            taskID: section.shortID,
            sectionPath: .path(newPath),
            text: newTitle,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Notes are a top-level-task feature only — Listo's model is
    /// deliberately two levels (task, subtask), and only the task carries a
    /// note. Called with a subtask's id, this throws instead of writing one.
    @discardableResult
    public func setNote(taskID: UUID, note: String?) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard document.depth(of: task) == 0 else { throw ListoEditorError.subtaskNoteNotSupported }
        let ownLine = task.lineRange!.lowerBound
        let (indent, _) = splitIndent(lines[ownLine])
        let existingCount = task.note.map { $0.components(separatedBy: "\n").count } ?? 0
        let existingRange = (ownLine + 1)..<(ownLine + 1 + existingCount)
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }

        let noteIndent = indent + "  "
        let newLines: [String] = (note?.isEmpty == false)
            ? note!.components(separatedBy: "\n").map { $0.isEmpty ? "" : noteIndent + $0 }
            : []

        lines.replaceSubrange(existingRange, with: newLines)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .noteUpdated,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: task.text,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Inserts a new, initially empty sibling task immediately after
    /// `taskID`, at the same nesting level — a subtask gets a subtask
    /// sibling, a top-level task gets a top-level sibling — for Modo App's
    /// "press Return, keep typing the next item" flow. Placed after the
    /// anchor's whole block (its note and, for a top-level task, its
    /// subtasks), so pressing Return on a task that already has subtasks
    /// adds the new sibling below all of them, not in between.
    @discardableResult
    public func insertTaskAfter(taskID: UUID, text: String) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, _) = document.location(of: task) else { throw ListoEditorError.taskNotFound }
        let ownLine = task.lineRange!.lowerBound
        let (indent, _) = splitIndent(lines[ownLine])
        let insertionIndex = fullRange(of: task).upperBound
        lines.insert(indent + "- [ ] " + text, at: insertionIndex)
        try commit(trackingLine: insertionIndex)

        let sectionPath = document.path(to: refetch(section)) ?? [section.title]
        let created = taskAt(line: insertionIndex)
        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .created,
            taskID: created?.shortID ?? "t_????",
            sectionPath: .path(sectionPath),
            text: created.map { document.logText(for: $0) } ?? text,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Listo's task tree is deliberately two levels deep: a task, and its
    /// (unnested) subtasks. `1` here means "a top-level task may gain
    /// subtasks, but a subtask may not gain subtasks of its own."
    public static let maxSubtaskDepth = 1

    /// Converts a top-level task into a subtask of whichever sibling
    /// immediately precedes it — the ⇥/Tab action. A task that is already a
    /// subtask cannot be indented further (`maxSubtaskDepth`).
    @discardableResult
    public func indentTask(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task) else {
            throw ListoEditorError.taskNotFound
        }
        guard document.depth(of: task) < Self.maxSubtaskDepth else {
            throw ListoEditorError.maxDepthReached
        }
        // The sibling *above it on screen* (display order), which is not
        // necessarily the one above it in the file once priorities differ.
        let siblings = parent?.displaySubtasks ?? section.displayTasks
        guard let taskIndex = siblings.firstIndex(where: { $0.id == task.id }), taskIndex > 0 else {
            throw ListoEditorError.noPrecedingSibling
        }
        let precedingSibling = siblings[taskIndex - 1]
        // Logged under its new parent — the relationship the action created.
        let logText = document.logText(for: task, parent: .some(precedingSibling))

        let sourceRange = fullRange(of: task)
        var block = Array(lines[sourceRange])
        block = block.map { $0.isEmpty ? $0 : "  " + $0 }
        lines.removeSubrange(sourceRange)

        var insertionIndex = fullRange(of: precedingSibling).upperBound
        if sourceRange.upperBound <= insertionIndex {
            insertionIndex -= sourceRange.count
        }
        lines.insert(contentsOf: block, at: insertionIndex)
        try commit(trackingLine: insertionIndex)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .reindented,
            taskID: task.shortID,
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Converts a subtask into a sibling of its own parent, placed right
    /// after the parent's whole block, one level shallower — the
    /// ⇧⇥/Shift+Tab action. A task already at the top level has nothing to
    /// outdent into and throws `alreadyTopLevel`.
    ///
    /// Any siblings that followed `task` under the same parent are left
    /// where they are (not absorbed as its new children) — simpler and
    /// more predictable than full outliner promote-with-descendants
    /// semantics, and sufficient for "change level with Tab/Shift+Tab."
    @discardableResult
    public func outdentTask(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task), let parentTask = parent else {
            throw ListoEditorError.alreadyTopLevel
        }
        // Logged under the parent it just left, so the line says what it was
        // taken out of.
        let logText = document.logText(for: task)

        let sourceRange = fullRange(of: task)
        var block = Array(lines[sourceRange])
        block = block.map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst(1)) }
            if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
            return line
        }
        lines.removeSubrange(sourceRange)

        var insertionIndex = fullRange(of: parentTask).upperBound
        if sourceRange.upperBound <= insertionIndex {
            insertionIndex -= sourceRange.count
        }
        lines.insert(contentsOf: block, at: insertionIndex)
        try commit(trackingLine: insertionIndex)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .reindented,
            taskID: task.shortID,
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Moves a task (with its note and subtasks) one position up
    /// (`direction: -1`) or down (`direction: +1`) among its own siblings —
    /// the ⌘↑/⌘↓ action. A subtask stays inside its parent and a top-level
    /// task stays inside its section; already first/last throws
    /// `noSiblingInDirection`.
    @discardableResult
    public func reorderTask(taskID: UUID, direction: Int) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task) else {
            throw ListoEditorError.taskNotFound
        }
        // Siblings are displayed sorted by priority, so "up/down" means
        // among the ones on screen — and only within the same priority: the
        // file order is the user's custom order *inside* a priority, while
        // crossing into another one is what `setPriority` is for.
        let siblings = parent?.displaySubtasks ?? section.displayTasks
        guard let taskIndex = siblings.firstIndex(where: { $0.id == task.id }),
              siblings.indices.contains(taskIndex + direction),
              siblings[taskIndex + direction].priority == task.priority
        else { throw ListoEditorError.noSiblingInDirection }
        let neighbor = siblings[taskIndex + direction]
        let logText = document.logText(for: task)

        let sourceRange = fullRange(of: task)
        let block = Array(lines[sourceRange])
        lines.removeSubrange(sourceRange)

        // The neighbor is adjacent, so going up it starts where the block
        // came out of; going down it ends `sourceRange.count` lines earlier
        // than it used to.
        let insertionIndex = direction < 0
            ? fullRange(of: neighbor).lowerBound
            : fullRange(of: neighbor).upperBound - sourceRange.count
        lines.insert(contentsOf: block, at: insertionIndex)
        try commit(trackingLine: insertionIndex)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .reordered,
            taskID: task.shortID,
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Moves a top-level task to another top-level section (drag & drop, or
    /// the section menu — spec §03/§04).
    @discardableResult
    public func moveTask(taskID: UUID, toSectionID targetSectionID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (sourceSection, parent) = document.location(of: task), parent == nil else {
            throw ListoEditorError.taskNotFound
        }
        guard let targetSection = document.allSectionsRecursive.first(where: { $0.id == targetSectionID }) else {
            throw ListoEditorError.sectionNotFound
        }
        let fromPath = document.path(to: sourceSection) ?? [sourceSection.title]
        let toPath = document.path(to: targetSection) ?? [targetSection.title]

        let sourceRange = fullRange(of: task)
        let targetInsertionIndex = targetSection.tasks.last.map { fullRange(of: $0).upperBound }
            ?? (targetSection.lineRange?.lowerBound ?? lines.count - 1) + 1

        let block = Array(lines[sourceRange])
        lines.removeSubrange(sourceRange)

        let adjustedIndex = targetInsertionIndex >= sourceRange.upperBound
            ? targetInsertionIndex - sourceRange.count
            : targetInsertionIndex
        lines.insert(contentsOf: block, at: adjustedIndex)
        try commit(trackingLine: adjustedIndex)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .movedSection,
            taskID: task.shortID,
            sectionPath: .move(from: fromPath, to: toPath),
            text: task.text,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    @discardableResult
    public func deleteTask(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        let section = document.location(of: task)?.section
        let path = section.map { document.path(to: $0) ?? [$0.title] }
        let logText = document.logText(for: task)

        let range = fullRange(of: task)
        lines.removeSubrange(range)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .deleted,
            taskID: task.shortID,
            sectionPath: path.map { .path($0) },
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    /// Deletes an entire section — its heading, its own tasks, and every
    /// nested subsection — in one go.
    @discardableResult
    public func deleteSection(sectionID: UUID) throws -> LogEvent {
        guard let section = document.allSectionsRecursive.first(where: { $0.id == sectionID }),
              let range = section.lineRange else {
            throw ListoEditorError.sectionNotFound
        }
        let path = document.path(to: section) ?? [section.title]

        lines.removeSubrange(range)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .deleted,
            taskID: section.shortID,
            sectionPath: .path(path),
            text: section.title,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    public func readLog() throws -> [LogEvent] {
        try logWriter.readAll()
    }

    // MARK: - Internals

    /// Writes the current buffer to disk and re-parses it into `document`.
    private func commit() throws {
        let text = lines.joined(separator: "\n")
        if autoPersist {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        document = ListoParser.parse(text)
    }

    /// `commit()`, then records `lastActionTaskID` as whichever task ends
    /// up at `line` — the block's own line after `renameTask`/`indentTask`/
    /// `outdentTask`/`moveTask` moved or relabeled it, so those don't each
    /// have to pair `commit()` with a separate lookup themselves.
    private func commit(trackingLine line: Int) throws {
        try commit()
        lastActionTaskID = taskAt(line: line)?.id
    }

    private func findTask(_ id: UUID) -> ListoTask? {
        document.allTasksRecursive.first { $0.id == id } ?? document.looseTasks.first { $0.id == id }
    }

    /// After a mutation, section objects captured before the mutation are
    /// stale; re-resolve by title/level path from the *current* document so
    /// log events reflect the up-to-date tree.
    private func refetch(_ section: ListoSection) -> ListoSection {
        document.allSectionsRecursive.first { $0.title == section.title && $0.level == section.level } ?? section
    }

    /// Whichever task now starts at `line`, post-reparse — how a fresh
    /// `LogEvent`'s `taskID` and `lastActionTaskID` (a task's new
    /// content/position-derived id after an action that moved or relabeled
    /// it) are both resolved. Named `taskAt`, not `task`, since most call
    /// sites already have a local `let task` in scope.
    private func taskAt(line: Int) -> ListoTask? {
        document.allTasksRecursive.first { $0.lineRange?.lowerBound == line }
    }

    /// Contiguous line range spanning a task's own line, its note, and all of
    /// its subtasks (with their notes) — the block that must move together.
    private func fullRange(of task: ListoTask) -> Range<Int> {
        guard let own = task.lineRange else { return 0..<0 }
        var end = own.upperBound + (task.note.map { $0.components(separatedBy: "\n").count } ?? 0)
        for sub in task.subtasks {
            end = max(end, fullRange(of: sub).upperBound)
        }
        return own.lowerBound..<end
    }

    private func splitIndent(_ line: String) -> (indent: String, rest: Substring) {
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
