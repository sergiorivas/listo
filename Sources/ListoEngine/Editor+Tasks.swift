import Foundation

// Task content actions: add, toggle, rename, priority, note, insert.

extension ListoEditor {
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
        return try record(event)
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
        if newState == .done, task.priority != .none {
            // A finished task no longer needs a priority: drop the marker.
            // Reopening it does not bring it back.
            lines[line] = ListoSerializer.taskLine(indent: indent, state: .done, text: task.text, priority: .none)
        } else {
            // Only the checkbox changes; everything after it is kept exactly
            // as written.
            lines[line] = indent + "- \(box)" + rest.dropFirst(5)
        }
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
        return try record(event)
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
        return try record(event)
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
        return try record(event)
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
        return try record(event)
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
        return try record(event)
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
        return try record(event)
    }
}
