import Foundation

// Archiving finished tasks out of the list into a sibling file.

extension ListoEditor {
    /// Where a list's archived tasks go: `Name.archive.md` next to it — an
    /// ordinary Listo file, so it opens and reads like any other list.
    public static func archiveURL(for documentURL: URL) -> URL {
        let base = documentURL.deletingPathExtension().lastPathComponent
        return documentURL.deletingLastPathComponent().appendingPathComponent("\(base).archive.md")
    }

    public var archiveURL: URL { Self.archiveURL(for: fileURL) }

    /// The finished top-level tasks archiving would move, in file order.
    public var archivableTasks: [ListoTask] {
        document.allSectionsRecursive.flatMap { $0.tasks.filter { $0.state == .done } }
    }

    /// Moves every finished top-level task (with its note and subtasks,
    /// whatever their state) out of the list and appends it to
    /// `archiveURL`, under an `# Archived YYYY-MM-DD` heading and a `##`
    /// heading per section it came from.
    ///
    /// One undo step that restores both files. One `archived` log event per
    /// task. Throws `nothingToArchive` when there is nothing done.
    @discardableResult
    public func archiveCompletedTasks() throws -> [LogEvent] {
        let tasks = archivableTasks
        guard !tasks.isEmpty else { throw ListoEditorError.nothingToArchive }

        var block = ["# Archived \(today().token.dropFirst())"]
        var events: [LogEvent] = []
        var ranges: [Range<Int>] = []
        for section in document.allSectionsRecursive {
            let done = section.tasks.filter { $0.state == .done }
            guard !done.isEmpty else { continue }
            let path = document.path(to: section) ?? [section.title]
            block += ["", "## " + path.joined(separator: " / ")]
            for task in done {
                let range = fullRange(of: task)
                ranges.append(range)
                block += lines[range]
                events.append(LogEvent(
                    file: fileURL.lastPathComponent,
                    event: .archived,
                    taskID: task.shortID,
                    sectionPath: .path(path),
                    text: document.logText(for: task),
                    source: .app,
                    interpretedBy: .userAction
                ))
            }
        }

        let url = archiveURL
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var archive = existing?.trimmingCharacters(in: .newlines) ?? ""
        if !archive.isEmpty { archive += "\n\n" }
        archive += block.joined(separator: "\n") + "\n"

        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            lines.removeSubrange(range)
        }
        try archive.write(to: url, atomically: true, encoding: .utf8)
        pendingSidecar = SidecarChange(url: url, before: existing, after: archive)
        try commit()

        var logged = [try record(events[0])]
        for event in events.dropFirst() { logged.append(try logWriter.append(event)) }
        return logged
    }
}
