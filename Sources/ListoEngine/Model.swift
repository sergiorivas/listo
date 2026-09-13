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

    /// All tasks in this section and its subsections, depth-first.
    public var allTasksRecursive: [ListoTask] {
        var result: [ListoTask] = []
        for t in tasks {
            result.append(t)
            result.append(contentsOf: t.subtasks)
        }
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

    /// Finds the section directly containing `task` (not recursively through
    /// subsections), along with the task's parent task if it is a subtask.
    public func location(of task: ListoTask) -> (section: ListoSection, parent: ListoTask?)? {
        func search(_ nodes: [ListoSection]) -> (ListoSection, ListoTask?)? {
            for section in nodes {
                for t in section.tasks {
                    if t.id == task.id { return (section, nil) }
                    if t.subtasks.contains(where: { $0.id == task.id }) {
                        return (section, t)
                    }
                }
                if let found = search(section.subsections) { return found }
            }
            return nil
        }
        return search(sections)
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
