import Foundation

// Structural actions: indent, outdent, reorder, split, group, move, delete.

extension ListoEditor {
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
        return try record(event)
    }

    /// Converts a subtask into a sibling of its own parent, placed right
    /// after the parent's whole block, one level shallower — the
    /// ⇧⇥/Shift+Tab action. A task already at the top level has nothing to
    /// outdent into and throws `alreadyTopLevel`.
    ///
    /// By default, any siblings that followed `task` under the same parent
    /// are left where they are (not absorbed as its new children): the task
    /// jumps to right after its parent's block. With
    /// `absorbingFollowingSiblings` the task instead stays put in the file
    /// and just loses a level, so the siblings after it become *its*
    /// subtasks (Workflowy-style).
    @discardableResult
    public func outdentTask(taskID: UUID, absorbingFollowingSiblings: Bool = false) throws -> LogEvent {
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
        let insertionIndex: Int
        if absorbingFollowingSiblings {
            lines.replaceSubrange(sourceRange, with: block)
            insertionIndex = sourceRange.lowerBound
        } else {
            lines.removeSubrange(sourceRange)
            var index = fullRange(of: parentTask).upperBound
            if sourceRange.upperBound <= index {
                index -= sourceRange.count
            }
            lines.insert(contentsOf: block, at: index)
            insertionIndex = index
        }
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
        return try record(event)
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
        return try record(event)
    }

    /// Replaces a top-level task with one top-level task per subtask, named
    /// `Parent > Sub`, in the same place — the ⌘T action. Each keeps its
    /// subtask's state and priority (falling back to the parent's priority
    /// when open); the parent's note, if any, is copied onto each so no
    /// content is lost.
    @discardableResult
    public func splitTask(taskID: UUID) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task), parent == nil else {
            throw ListoEditorError.taskNotFound
        }
        guard !task.subtasks.isEmpty else { throw ListoEditorError.noSubtasksToSplit }
        let logText = document.logText(for: task)
        let (indent, _) = splitIndent(lines[task.lineRange!.lowerBound])
        let noteLines: [String] = task.note.map {
            $0.components(separatedBy: "\n").map { $0.isEmpty ? "" : indent + "  " + $0 }
        } ?? []

        var newLines: [String] = []
        for sub in task.subtasks {
            let priority = sub.priority != .none ? sub.priority : task.priority
            newLines.append(ListoSerializer.taskLine(
                indent: indent, state: sub.state, text: "\(task.text) > \(sub.text)",
                priority: sub.state == .done ? .none : priority))
            newLines.append(contentsOf: noteLines)
        }
        let start = task.lineRange!.lowerBound
        lines.replaceSubrange(fullRange(of: task), with: newLines)
        try commit(trackingLine: start)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .split,
            taskID: task.shortID,
            sectionPath: .path(document.path(to: refetch(section)) ?? [section.title]),
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try record(event)
    }

    /// Name given to a group whose tasks share no common prefix.
    public static let defaultGroupName = "Grouped Task"

    /// Merges two or more top-level tasks of one section into a single task
    /// whose subtasks are the originals — the ⌘G action, inverse of
    /// `splitTask`. The group takes the place of the first of them (file
    /// order) and is named after their common prefix (whole words, trailing
    /// separators like `>` or `:` dropped), else `defaultGroupName`; each
    /// subtask keeps its state and priority and loses that prefix. Tasks
    /// carrying a note or subtasks are refused rather than losing content.
    @discardableResult
    public func groupTasks(taskIDs: [UUID]) throws -> LogEvent {
        let found = taskIDs.compactMap { findTask($0) }
        guard found.count == taskIDs.count, Set(taskIDs).count == taskIDs.count else {
            throw ListoEditorError.taskNotFound
        }
        guard found.count >= 2 else { throw ListoEditorError.cannotGroup }
        let tasks = found.sorted { $0.lineRange!.lowerBound < $1.lineRange!.lowerBound }
        guard let (section, parent) = document.location(of: tasks[0]), parent == nil else {
            throw ListoEditorError.cannotGroup
        }
        for task in tasks {
            guard let location = document.location(of: task), location.parent == nil,
                  location.section.id == section.id else { throw ListoEditorError.cannotGroup }
            guard task.note == nil, task.subtasks.isEmpty else { throw ListoEditorError.groupedTaskHasContent }
        }

        let prefix = Self.commonPrefix(of: tasks.map(\.text))
        let name = prefix ?? Self.defaultGroupName
        let (indent, _) = splitIndent(lines[tasks[0].lineRange!.lowerBound])
        let groupState: TaskState = tasks.allSatisfy { $0.state == .done } ? .done : .open

        var newLines = [ListoSerializer.taskLine(indent: indent, state: groupState, text: name, priority: .none)]
        for task in tasks {
            var text = task.text
            if let prefix {
                let rest = String(text.dropFirst(prefix.count))
                    .drop { $0.isWhitespace || ">:-–—".contains($0) }
                if !rest.isEmpty { text = String(rest) }
            }
            newLines.append(ListoSerializer.taskLine(indent: indent + "  ", state: task.state, text: text, priority: task.priority))
        }

        let start = tasks[0].lineRange!.lowerBound
        let logText = name
        let sectionPath = document.path(to: section) ?? [section.title]
        // Remove from the bottom so earlier ranges stay valid, then put the
        // group where the first task was.
        for task in tasks.reversed() { lines.removeSubrange(fullRange(of: task)) }
        lines.insert(contentsOf: newLines, at: start)
        try commit(trackingLine: start)

        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: .grouped,
            taskID: taskAt(line: start)?.shortID ?? "t_????",
            sectionPath: .path(sectionPath),
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try record(event)
    }

    /// The longest run of leading whole words shared by every text, with
    /// trailing separators trimmed; `nil` when there is none.
    static func commonPrefix(of texts: [String]) -> String? {
        let words = texts.map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
        guard var shared = words.first else { return nil }
        for other in words.dropFirst() {
            var n = 0
            while n < shared.count, n < other.count, shared[n] == other[n] { n += 1 }
            shared = Array(shared.prefix(n))
        }
        while let last = shared.last, last.allSatisfy({ ">:-–—,".contains($0) }) { shared.removeLast() }
        guard !shared.isEmpty else { return nil }
        var joined = shared.joined(separator: " ")
        while let last = joined.last, ":,-–—".contains(last) { joined.removeLast() }
        return joined.isEmpty ? nil : joined
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
        return try record(event)
    }

    /// Drag-and-drop onto a task: moves `taskID` (note and subtasks included)
    /// just before or after `targetID`, or nests it as the target's last
    /// subtask.
    ///
    /// - Before/after needs the same level on both sides, so a top-level
    ///   task can land in another section but never between subtasks; a
    ///   subtask dropped next to a subtask of a different parent changes
    ///   parent.
    /// - `asSubtask` takes a top-level target; a top-level task being nested
    ///   must have no note or subtasks (`taskHasContent`).
    /// - Only file order changes. Views still sort by priority, so a drop
    ///   next to a task of another priority has no visible effect on its own;
    ///   callers that care (the drag UI) check that first.
    @discardableResult
    public func moveTask(taskID: UUID, relativeTo targetID: UUID, placement: DropPlacement) throws -> LogEvent {
        guard let task = findTask(taskID), let target = findTask(targetID),
              let (section, parent) = document.location(of: task),
              let (targetSection, targetParent) = document.location(of: target)
        else { throw ListoEditorError.taskNotFound }
        let sourceRange = fullRange(of: task)
        let targetRange = fullRange(of: target)
        guard task.id != target.id, !sourceRange.overlaps(targetRange) else { throw ListoEditorError.invalidMove }

        let indentsBlock: Bool
        let newParent: ListoTask?
        switch placement {
        case .before, .after:
            guard (parent == nil) == (targetParent == nil) else { throw ListoEditorError.invalidMove }
            indentsBlock = false
            newParent = targetParent
        case .asSubtask:
            guard targetParent == nil else { throw ListoEditorError.invalidMove }
            if parent == nil {
                guard task.subtasks.isEmpty, task.note == nil else { throw ListoEditorError.taskHasContent }
            }
            indentsBlock = parent == nil
            newParent = target
        }

        let fromPath = document.path(to: section) ?? [section.title]
        let toPath = document.path(to: targetSection) ?? [targetSection.title]
        let changesParent = newParent?.id != parent?.id
        let logText = changesParent ? document.logText(for: task, parent: .some(newParent)) : document.logText(for: task)

        var block = Array(lines[sourceRange])
        if indentsBlock { block = block.map { $0.isEmpty ? $0 : "  " + $0 } }
        var insertionIndex = placement == .before ? targetRange.lowerBound : targetRange.upperBound
        lines.removeSubrange(sourceRange)
        if sourceRange.upperBound <= insertionIndex { insertionIndex -= sourceRange.count }
        lines.insert(contentsOf: block, at: insertionIndex)
        try commit(trackingLine: insertionIndex)

        let kind: LogEvent.Kind
        let sectionPath: LogEvent.SectionPath
        if changesParent {
            kind = .reindented
            sectionPath = .path(document.path(to: refetch(targetSection)) ?? [targetSection.title])
        } else if section.id != targetSection.id {
            kind = .movedSection
            sectionPath = .move(from: fromPath, to: toPath)
        } else {
            kind = .reordered
            sectionPath = .path(document.path(to: refetch(section)) ?? [section.title])
        }
        let event = LogEvent(
            file: fileURL.lastPathComponent,
            event: kind,
            taskID: task.shortID,
            sectionPath: sectionPath,
            text: logText,
            source: .app,
            interpretedBy: .userAction
        )
        return try record(event)
    }

    /// Moves a top-level task to the end of the previous (`direction: -1`) or
    /// next (`direction: +1`) top-level section — the ⌘←/⌘→ action in Kanban,
    /// where top-level sections are the columns. A task inside a column's
    /// subgroup counts as being in that column. Subtasks never leave their
    /// parent, and there being no column that way, throw
    /// `noSectionInDirection`.
    @discardableResult
    public func moveTaskToAdjacentSection(taskID: UUID, direction: Int) throws -> LogEvent {
        guard let task = findTask(taskID) else { throw ListoEditorError.taskNotFound }
        guard let (section, parent) = document.location(of: task) else {
            throw ListoEditorError.taskNotFound
        }
        func contains(_ node: ListoSection) -> Bool {
            node.id == section.id || node.subsections.contains(where: contains)
        }
        guard parent == nil,
              let columnIndex = document.sections.firstIndex(where: contains),
              document.sections.indices.contains(columnIndex + direction)
        else { throw ListoEditorError.noSectionInDirection }
        return try moveTask(taskID: taskID, toSectionID: document.sections[columnIndex + direction].id)
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
        return try record(event)
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
        return try record(event)
    }
}
