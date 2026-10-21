import Foundation

/// What the search field and filter menu narrow the views down to. Purely a
/// display concern: the file and every editor action still see all tasks.
public struct TaskFilter: Equatable, Sendable {
    public enum State: Sendable { case any, open, done }
    public enum Due: Sendable { case any, overdue, today, thisWeek, hasDate, noDate }

    /// Whitespace-separated words that must all appear (case- and
    /// diacritic-insensitive) in the task's text or note.
    public var query = ""
    public var state: State = .any
    /// Show only tasks at least this important.
    public var minPriority: TaskPriority = .none
    /// A tag, lowercased and without the `#`.
    public var tag: String?
    public var due: Due = .any

    public init() {}

    public var isActive: Bool { self != TaskFilter() }

    /// Whether `task` itself passes every criterion.
    public func matches(_ task: ListoTask, today: TaskDueDate = TaskDueDate(date: Date())) -> Bool {
        let metadata = task.metadata
        switch state {
        case .any: break
        case .open: if task.state == .done { return false }
        case .done: if task.state != .done { return false }
        }
        if task.priority < minPriority { return false }
        if let tag, !metadata.tags.contains(tag) { return false }
        switch due {
        case .any: break
        case .noDate: if metadata.due != nil { return false }
        case .hasDate: if metadata.due == nil { return false }
        case .overdue, .today, .thisWeek:
            guard let date = metadata.due else { return false }
            let status = DueStatus(due: date, today: today)
            switch due {
            case .overdue: if status != .overdue { return false }
            case .today: if status != .today { return false }
            default: if status == .later { return false }   // overdue, today or within the week
            }
        }
        let words = query.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty {
            let haystack = [task.text, task.note ?? ""].joined(separator: "\n")
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            for word in words where haystack.range(of: String(word), options: options) == nil {
                return false
            }
        }
        return true
    }

    /// Whether `task` should show: it passes, or one of its subtasks does
    /// (a matching subtask can't be shown without its parent).
    public func showsTree(_ task: ListoTask, today: TaskDueDate = TaskDueDate(date: Date())) -> Bool {
        !isActive || matches(task, today: today) || task.subtasks.contains { showsTree($0, today: today) }
    }

    /// `tasks` (already in display order) minus what the filter hides.
    public func visible(_ tasks: [ListoTask], today: TaskDueDate = TaskDueDate(date: Date())) -> [ListoTask] {
        isActive ? tasks.filter { showsTree($0, today: today) } : tasks
    }

    /// `parent`'s subtasks to show: all of them when the parent itself
    /// passes, otherwise only the ones that do.
    public func visibleSubtasks(of parent: ListoTask, today: TaskDueDate = TaskDueDate(date: Date())) -> [ListoTask] {
        let subtasks = parent.displaySubtasks
        guard isActive, !matches(parent, today: today) else { return subtasks }
        return subtasks.filter { showsTree($0, today: today) }
    }

    /// Number of tasks in `section` and its subsections that show.
    public func count(in section: ListoSection, today: TaskDueDate = TaskDueDate(date: Date())) -> Int {
        visible(section.tasks, today: today).count + section.subsections.reduce(0) { $0 + count(in: $1, today: today) }
    }

    /// The tasks the views show for `section` (and its subsections), in the
    /// order they show them — what ↑/↓ navigation walks.
    public func displayOrder(in section: ListoSection, today: TaskDueDate = TaskDueDate(date: Date())) -> [ListoTask] {
        func walk(_ tasks: [ListoTask]) -> [ListoTask] {
            visible(ListoTask.sortedByPriority(tasks), today: today).flatMap { task in
                [task] + visibleSubtasks(of: task, today: today)
            }
        }
        return walk(section.tasks) + section.subsections.flatMap { displayOrder(in: $0, today: today) }
    }

    public func displayOrder(in document: ListoDocument, today: TaskDueDate = TaskDueDate(date: Date())) -> [ListoTask] {
        document.sections.flatMap { displayOrder(in: $0, today: today) }
    }
}
