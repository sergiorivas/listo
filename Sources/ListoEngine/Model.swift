import Foundation

/// Checklist state of a task line (`- [ ]` vs `- [x]`).
public enum TaskState: String, Codable, Sendable {
    case open
    case done
}

/// A single task or subtask. Identity (`id`) is ephemeral and in-memory only —
/// it is never written to the markdown file (see spec §09: task identity is
/// resolved by position + text matching, not a stored id).
public final class ListoTask: Identifiable {
    public let id: UUID
    public var text: String
    public var state: TaskState
    /// Free markdown text indented under the task (links, code fences, prose).
    /// Treated as one opaque blob for diffing purposes (spec §05).
    public var note: String?
    public var subtasks: [ListoTask]
    /// Line range in the source buffer this task (including its note and
    /// subtasks) occupies, 0-indexed, inclusive-exclusive. Used to make
    /// minimal, targeted edits instead of rewriting the whole file.
    public var lineRange: Range<Int>?

    public init(
        id: UUID = UUID(),
        text: String,
        state: TaskState = .open,
        note: String? = nil,
        subtasks: [ListoTask] = [],
        lineRange: Range<Int>? = nil
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.note = note
        self.subtasks = subtasks
        self.lineRange = lineRange
    }

    /// Short id used in log lines (e.g. "t_8f2a"), stable for the lifetime of
    /// this in-memory object only.
    public var shortID: String {
        "t_" + id.uuidString.prefix(4).lowercased()
    }
}

/// A markdown heading (`#`, `##`, `###` — levels 1...3) that groups tasks and
/// nested sub-sections. Level-1 sections are the Kanban columns.
public final class ListoSection: Identifiable {
    public let id: UUID
    public var title: String
    public var level: Int // 1, 2, or 3
    public var tasks: [ListoTask]
    public var subsections: [ListoSection]
    public var lineRange: Range<Int>?

    public init(
        id: UUID = UUID(),
        title: String,
        level: Int,
        tasks: [ListoTask] = [],
        subsections: [ListoSection] = [],
        lineRange: Range<Int>? = nil
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.tasks = tasks
        self.subsections = subsections
        self.lineRange = lineRange
    }

    /// Short id used in log lines, same shape as `ListoTask.shortID`
    /// (e.g. "s_8f2a"), stable for the lifetime of this in-memory object only.
    public var shortID: String {
        "s_" + id.uuidString.prefix(4).lowercased()
    }

    /// All tasks in this section and its subsections, depth-first — every
    /// nesting level of subtask, not just the first.
    public var allTasksRecursive: [ListoTask] {
        func walk(_ tasks: [ListoTask]) -> [ListoTask] {
            tasks.flatMap { [$0] + walk($0.subtasks) }
        }
        var result = walk(tasks)
        for s in subsections {
            result.append(contentsOf: s.allTasksRecursive)
        }
        return result
    }
}

/// The parsed tree for one `.md` file, plus the raw source text it was
/// parsed from (kept around so edits can be applied as minimal line-level
/// diffs rather than a full re-serialization).
public struct ListoDocument {
    public var sections: [ListoSection]
    public var rawText: String
    /// Tasks appearing before any heading in the file. Rare in practice —
    /// the spec's examples always start with a heading — but kept so no
    /// content is silently dropped.
    public var looseTasks: [ListoTask] = []

    public init(sections: [ListoSection], rawText: String) {
        self.sections = sections
        self.rawText = rawText
    }

    /// Path of section titles from the top-level column down to (and
    /// including) `section`, e.g. `["backlog", "prioridad 2"]`.
    public func path(to section: ListoSection) -> [String]? {
        func search(_ nodes: [ListoSection], trail: [String]) -> [String]? {
            for node in nodes {
                let newTrail = trail + [node.title]
                if node.id == section.id { return newTrail }
                if let found = search(node.subsections, trail: newTrail) {
                    return found
                }
            }
            return nil
        }
        return search(sections, trail: [])
    }

    /// Finds the section containing `task` (searching subsections too),
    /// along with its direct parent task at any subtask nesting depth —
    /// `nil` if `task` is itself a top-level task in that section.
    public func location(of task: ListoTask) -> (section: ListoSection, parent: ListoTask?)? {
        // Outer optional: "found within this list or not". Inner optional:
        // the parent itself, which is legitimately nil for a top-level task.
        func searchTasks(_ tasks: [ListoTask], parent: ListoTask?) -> ListoTask?? {
            for t in tasks {
                if t.id == task.id { return .some(parent) }
                if !t.subtasks.isEmpty, let found = searchTasks(t.subtasks, parent: t) {
                    return found
                }
            }
            return nil
        }
        func search(_ nodes: [ListoSection]) -> (ListoSection, ListoTask?)? {
            for section in nodes {
                if let found = searchTasks(section.tasks, parent: nil) {
                    return (section, found)
                }
                if let found = search(section.subsections) { return found }
            }
            return nil
        }
        return search(sections)
    }

    /// Nesting depth of `task` — 0 for a top-level task, 1 for its direct
    /// subtask, and so on.
    public func depth(of task: ListoTask) -> Int {
        var current = task
        var depth = 0
        while let parent = location(of: current)?.parent {
            depth += 1
            current = parent
        }
        return depth
    }

    /// How `task` is named in the log: its own text for a top-level task, or
    /// `<task> > <subtask>` (every ancestor, outermost first) for a subtask,
    /// so a log line about a subtask carries the context of what it belongs
    /// to. `text` overrides the task's own text (a rename logs the new one),
    /// and `parent` overrides the lookup for actions that change the task's
    /// parent (indent/outdent), where the caller knows which one to show.
    public func logText(for task: ListoTask, text: String? = nil, parent: ListoTask?? = nil) -> String {
        var names = [text ?? task.text]
        var current: ListoTask? = parent ?? location(of: task)?.parent
        while let ancestor = current {
            names.insert(ancestor.text, at: 0)
            current = location(of: ancestor)?.parent
        }
        return names.joined(separator: " > ")
    }

    public var allSectionsRecursive: [ListoSection] {
        func flatten(_ nodes: [ListoSection]) -> [ListoSection] {
            nodes.flatMap { [$0] + flatten($0.subsections) }
        }
        return flatten(sections)
    }

    public var allTasksRecursive: [ListoTask] {
        sections.flatMap { $0.allTasksRecursive }
    }
}
