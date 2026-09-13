import Foundation

public enum ListoEditorError: Error {
    case taskNotFound
    case sectionNotFound
    case noPrecedingSibling
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
    /// editor (an external write picked up by the watcher, or the host
    /// document's own text binding after a Modo Libre edit).
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
            taskID: taskID(atLine: insertionIndex) ?? "t_????",
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
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }
        lines[line] = indent + "- \(box) " + task.text
        _ = rest
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: newState == .done ? .completed : .reopened,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: task.text,
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
        let box = task.state == .done ? "[x]" : "[ ]"
        let sectionPath = (document.location(of: task)?.section).map { document.path(to: $0) ?? [$0.title] }
        lines[line] = indent + "- \(box) " + newText
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .edited,
            taskID: task.shortID,
            sectionPath: sectionPath.map { .path($0) },
            text: newText,
            source: .app,
            interpretedBy: .userAction
        )
        return try logWriter.append(event)
    }

    @discardableResult
    public func setNote(taskID: UUID, note: String?) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
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

    /// Converts a top-level task into a subtask of the task immediately
    /// preceding it in the same section (spec §03 "Indentar").
    @discardableResult
    public func indentTask(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task), parent == nil else {
            throw ListoEditorError.taskNotFound
        }
        guard let taskIndex = section.tasks.firstIndex(where: { $0.id == task.id }), taskIndex > 0 else {
            throw ListoEditorError.noPrecedingSibling
        }
        let precedingSibling = section.tasks[taskIndex - 1]

        let sourceRange = fullRange(of: task)
        var block = Array(lines[sourceRange])
        block = block.map { $0.isEmpty ? $0 : "  " + $0 }
        lines.removeSubrange(sourceRange)

        var insertionIndex = fullRange(of: precedingSibling).upperBound
        if sourceRange.upperBound <= insertionIndex {
            insertionIndex -= sourceRange.count
        }
        lines.insert(contentsOf: block, at: insertionIndex)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .reindented,
            taskID: task.shortID,
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: task.text,
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
        try commit()

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

        let range = fullRange(of: task)
        lines.removeSubrange(range)
        try commit()

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .deleted,
            taskID: task.shortID,
            sectionPath: path.map { .path($0) },
            text: task.text,
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

    private func findTask(_ id: UUID) -> ListoTask? {
        document.allTasksRecursive.first { $0.id == id } ?? document.looseTasks.first { $0.id == id }
    }

    /// After a mutation, section objects captured before the mutation are
    /// stale; re-resolve by title/level path from the *current* document so
    /// log events reflect the up-to-date tree.
    private func refetch(_ section: ListoSection) -> ListoSection {
        document.allSectionsRecursive.first { $0.title == section.title && $0.level == section.level } ?? section
    }

    private func taskID(atLine line: Int) -> String? {
        document.allTasksRecursive.first { $0.lineRange?.lowerBound == line }?.shortID
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
