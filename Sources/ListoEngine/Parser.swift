import Foundation

/// Parses the plain-markdown dialect described in the spec:
/// File → Section (H1/H2/H3, up to 3 levels) → Task → Subtask, with an
/// optional free-markdown note hanging off any task.
///
/// The indentation rule (spec §02): the indent unit is 2 spaces or one tab.
/// An indented line that starts with `- [ ]`/`- [x]` is a subtask; any other
/// indented line is part of the enclosing task's note.
public enum ListoParser {

    public static func parse(_ rawText: String) -> ListoDocument {
        let lines = rawText.components(separatedBy: "\n")

        var rootSections: [ListoSection] = []
        // stack[i] = the currently-open section at header level i+1
        var stack: [ListoSection] = []

        var looseTasks: [ListoTask] = []

        // Disambiguates duplicate seeds (e.g. two sibling tasks with the
        // identical text) so they still get distinct, but still stable
        // across reparses, ids — see `UUID.init(stableSeed:)`.
        var seedCounts: [String: Int] = [:]
        func nextID(seed: String) -> UUID {
            let count = seedCounts[seed, default: 0]
            seedCounts[seed] = count + 1
            return UUID(stableSeed: "\(seed)|#\(count)")
        }

        // Most recently parsed task at each indent level (0 = top-level task,
        // 1 = subtask). Notes attach to whichever of these is deepest/most
        // recent, since a note always immediately follows its owning task
        // line in source order.
        var lastTaskAtLevel: [Int: ListoTask] = [:]
        var mostRecentTask: ListoTask?
        // The indent level (in units) of mostRecentTask's own line — needed
        // to know exactly how much of a note line's leading whitespace is
        // structural (marking it as "this task's note") versus the note's
        // own content, so it can be stripped on the way in.
        var mostRecentTaskLevel = 0
        var noteBuffer: [String] = []

        func currentTargetSection() -> ListoSection? {
            stack.last
        }

        func indentLevel(of line: String) -> (level: Int, rest: Substring) {
            var s = Substring(line)
            var level = 0
            while true {
                if s.hasPrefix("\t") {
                    s = s.dropFirst()
                    level += 1
                } else if s.hasPrefix("  ") {
                    s = s.dropFirst(2)
                    level += 1
                } else {
                    break
                }
            }
            return (level, s)
        }

        /// Strips up to `count` indent units (2 spaces or 1 tab each) from
        /// the front of `line`, stopping early if it runs out of leading
        /// whitespace — any indentation beyond that is the note's own
        /// content (e.g. a nested list inside it), not structure.
        func stripUnits(_ line: String, count: Int) -> String {
            var s = Substring(line)
            var remaining = count
            while remaining > 0 {
                if s.hasPrefix("\t") {
                    s = s.dropFirst()
                } else if s.hasPrefix("  ") {
                    s = s.dropFirst(2)
                } else {
                    break
                }
                remaining -= 1
            }
            return String(s)
        }

        func finalizeNote() {
            defer { noteBuffer.removeAll() }
            guard let owner = mostRecentTask else { return }
            // Trim leading/trailing fully-blank lines but keep internal ones.
            var trimmed = noteBuffer
            while let first = trimmed.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                trimmed.removeFirst()
            }
            while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                trimmed.removeLast()
            }
            guard !trimmed.isEmpty else { return }
            // Store the note dedented (structural indent removed) so it
            // round-trips cleanly: ListoEditor.setNote/Serializer re-add
            // exactly this one indent unit when writing it back. Storing it
            // raw (with the indent baked in) meant re-editing an existing
            // note fed its already-indented text back into setNote, which
            // indented it *again* — one extra level of leading space added
            // on every save.
            let dedented = trimmed.map { stripUnits($0, count: mostRecentTaskLevel + 1) }
            owner.note = dedented.joined(separator: "\n")
        }

        func parseCheckbox(_ rest: Substring) -> (TaskState, String)? {
            guard rest.count >= 5 else { return nil }
            let prefix = rest.prefix(5)
            let lower = prefix.lowercased()
            guard lower == "- [ ]" || lower == "- [x]" else { return nil }
            let state: TaskState = lower == "- [x]" ? .done : .open
            var remainder = rest.dropFirst(5)
            if remainder.hasPrefix(" ") { remainder = remainder.dropFirst() }
            return (state, String(remainder))
        }

        for (idx, rawLine) in lines.enumerated() {
            // Header line? Headers are always at column 0.
            if let (level, title) = headerMatch(rawLine) {
                finalizeNote()
                lastTaskAtLevel.removeAll()
                mostRecentTask = nil

                // Close sections at level >= new level.
                while stack.count >= level { stack.removeLast() }

                let parentKey = stack.last?.id.uuidString ?? "root"
                let sectionID = nextID(seed: "section|\(parentKey)|\(level)|\(title)")
                let section = ListoSection(id: sectionID, title: title, level: level, lineRange: idx..<(idx + 1))
                if let parent = stack.last {
                    parent.subsections.append(section)
                } else {
                    rootSections.append(section)
                }
                stack.append(section)
                continue
            }

            let (level, rest) = indentLevel(of: rawLine)

            if let (state, text) = parseCheckbox(rest) {
                finalizeNote()

                let taskID: UUID
                if level == 0 {
                    let sectionKey = currentTargetSection()?.id.uuidString ?? "loose"
                    taskID = nextID(seed: "task|\(sectionKey)|top|\(text)")
                } else if let parentTask = lastTaskAtLevel[level - 1] {
                    taskID = nextID(seed: "task|sub|\(parentTask.id.uuidString)|\(text)")
                } else {
                    let sectionKey = currentTargetSection()?.id.uuidString ?? "loose"
                    taskID = nextID(seed: "task|\(sectionKey)|fallback|\(text)")
                }
                let task = ListoTask(id: taskID, text: text, state: state, lineRange: idx..<(idx + 1))

                if level == 0 {
                    if let section = currentTargetSection() {
                        section.tasks.append(task)
                    } else {
                        looseTasks.append(task)
                    }
                    lastTaskAtLevel = [0: task]
                } else {
                    // Subtask: attach to the nearest task one level up.
                    if let parentTask = lastTaskAtLevel[level - 1] {
                        parentTask.subtasks.append(task)
                    } else if let section = currentTargetSection() {
                        // Malformed nesting (no parent at level-1) — fall
                        // back to treating it as a top-level task so nothing
                        // is silently dropped.
                        section.tasks.append(task)
                    } else {
                        looseTasks.append(task)
                    }
                    lastTaskAtLevel[level] = task
                    // Clear deeper levels; they no longer have a valid parent chain.
                    for k in lastTaskAtLevel.keys where k > level {
                        lastTaskAtLevel.removeValue(forKey: k)
                    }
                }
                mostRecentTask = task
                mostRecentTaskLevel = level
                continue
            }

            // Not a header, not a task line.
            if level >= 1, mostRecentTask != nil {
                // Part of the current task's note (indented, non-task).
                noteBuffer.append(rawLine)
            } else if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank separator line — may or may not become part of a note;
                // finalizeNote()/further lines decide. Buffer it speculatively
                // only if we're already mid-note so internal blank lines survive.
                if !noteBuffer.isEmpty {
                    noteBuffer.append(rawLine)
                }
            } else {
                // Unindented stray content with no owning task — ignore for
                // structural purposes (not a header, not a task, not a note).
                finalizeNote()
                mostRecentTask = nil
                lastTaskAtLevel.removeAll()
            }
        }
        finalizeNote()

        // Close out lineRange.end for every section now that we know the
        // document length.
        func closeRanges(_ sections: [ListoSection]) {
            for (i, section) in sections.enumerated() {
                let nextSiblingStart = i + 1 < sections.count ? sections[i + 1].lineRange?.lowerBound : nil
                closeRanges(section.subsections)
                let childEnd = section.subsections.last?.lineRange?.upperBound
                let ownStart = section.lineRange?.lowerBound ?? 0
                let end = nextSiblingStart ?? childEnd ?? lines.count
                section.lineRange = ownStart..<max(end, ownStart + 1)
            }
        }
        closeRanges(rootSections)

        var doc = ListoDocument(sections: rootSections, rawText: rawText)
        doc.looseTasks = looseTasks
        return doc
    }

    private static func headerMatch(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        var hashes = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#" {
            hashes += 1
            idx = line.index(after: idx)
        }
        guard hashes >= 1, hashes <= 3 else { return nil }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let title = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (hashes, title)
    }
}
