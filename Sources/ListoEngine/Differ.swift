import Foundation

/// The result of comparing a document's before/after text in Modo Libre
/// (spec §05).
public enum DiffOutcome {
    /// A confident, heuristic-only read of what changed — safe to log
    /// directly with `interpretedBy: .heuristic`.
    case resolved([LogEvent])
    /// Several things changed at once in a way that makes matching
    /// uncertain (e.g. multiple tasks reordered/moved together). `guess`
    /// is the heuristic's best effort, offered only as a fallback for when
    /// no LLM is available; callers should prefer sending `oldText`/`newText`
    /// to an `LLMClient` and logging its answer instead (`interpretedBy: .llm`).
    case ambiguous(guess: [LogEvent], oldText: String, newText: String)
}

/// Compares two versions of the same file and turns the change into log
/// events, without ever touching the file itself (Modo Libre already wrote
/// it — this only interprets what happened, per spec §05).
public enum ListoDiffer {

    private struct FlatTask {
        let task: ListoTask
        let sectionPath: [String]
        let parentText: String?
        var normalizedText: String { task.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    public static func diff(fileName: String, oldText: String, newText: String) -> DiffOutcome {
        guard oldText != newText else { return .resolved([]) }

        let oldDoc = ListoParser.parse(oldText)
        let newDoc = ListoParser.parse(newText)
        let oldFlat = flatten(oldDoc)
        let newFlat = flatten(newDoc)

        var matchedOld = Set<Int>()
        var matchedNew = Set<Int>()
        var pairs: [(old: Int, new: Int, exact: Bool)] = []

        // Pass 1: exact normalized-text matches (cheap, unambiguous identity).
        for (ni, n) in newFlat.enumerated() {
            guard let oi = oldFlat.indices.first(where: {
                !matchedOld.contains($0) && oldFlat[$0].normalizedText == n.normalizedText
            }) else { continue }
            pairs.append((oi, ni, true))
            matchedOld.insert(oi)
            matchedNew.insert(ni)
        }

        // Pass 2: fuzzy matches for genuine text edits (best remaining pair
        // above a similarity threshold).
        var usedFuzzyMatch = false
        for (ni, n) in newFlat.enumerated() where !matchedNew.contains(ni) {
            var best: (idx: Int, score: Double)?
            for oi in oldFlat.indices where !matchedOld.contains(oi) {
                let score = similarity(oldFlat[oi].normalizedText, n.normalizedText)
                if score > 0.55, best == nil || score > best!.score {
                    best = (oi, score)
                }
            }
            if let best {
                pairs.append((best.idx, ni, false))
                matchedOld.insert(best.idx)
                matchedNew.insert(ni)
                usedFuzzyMatch = true
            }
        }

        var events: [LogEvent] = []
        var structuralChanges = 0

        for (oi, ni, exact) in pairs {
            let old = oldFlat[oi]
            let new = newFlat[ni]

            if !exact {
                events.append(LogEvent(
                    file: fileName, event: .edited, taskID: new.task.shortID,
                    sectionPath: .path(new.sectionPath), text: new.task.text,
                    source: .freeEdit, interpretedBy: .heuristic
                ))
            }
            if old.task.state != new.task.state {
                events.append(LogEvent(
                    file: fileName,
                    event: new.task.state == .done ? .completed : .reopened,
                    taskID: new.task.shortID, sectionPath: .path(new.sectionPath),
                    text: new.task.text, source: .freeEdit, interpretedBy: .heuristic
                ))
            }
            if old.sectionPath != new.sectionPath {
                events.append(LogEvent(
                    file: fileName, event: .movedSection, taskID: new.task.shortID,
                    sectionPath: .move(from: old.sectionPath, to: new.sectionPath),
                    text: new.task.text, source: .freeEdit, interpretedBy: .heuristic
                ))
                structuralChanges += 1
            }
            if (old.parentText != nil) != (new.parentText != nil) {
                events.append(LogEvent(
                    file: fileName, event: .reindented, taskID: new.task.shortID,
                    sectionPath: .path(new.sectionPath), text: new.task.text,
                    source: .freeEdit, interpretedBy: .heuristic
                ))
                structuralChanges += 1
            }
            if old.task.note != new.task.note {
                events.append(LogEvent(
                    file: fileName, event: .noteUpdated, taskID: new.task.shortID,
                    sectionPath: .path(new.sectionPath), text: new.task.text,
                    source: .freeEdit, interpretedBy: .heuristic
                ))
            }
        }

        for oi in oldFlat.indices where !matchedOld.contains(oi) {
            let old = oldFlat[oi]
            events.append(LogEvent(
                file: fileName, event: .deleted, taskID: old.task.shortID,
                sectionPath: .path(old.sectionPath), text: old.task.text,
                source: .freeEdit, interpretedBy: .heuristic
            ))
            structuralChanges += 1
        }
        for ni in newFlat.indices where !matchedNew.contains(ni) {
            let new = newFlat[ni]
            events.append(LogEvent(
                file: fileName, event: .created, taskID: new.task.shortID,
                sectionPath: .path(new.sectionPath), text: new.task.text,
                source: .freeEdit, interpretedBy: .heuristic
            ))
            structuralChanges += 1
        }

        // More than one structural change at once, or an identity match that
        // itself required fuzzy guessing, is exactly the "varias líneas se
        // movieron a la vez" case the spec calls out as needing an LLM.
        let isAmbiguous = structuralChanges > 1 || (usedFuzzyMatch && structuralChanges > 0)
        if isAmbiguous {
            return .ambiguous(guess: events, oldText: oldText, newText: newText)
        }
        return .resolved(events)
    }

    /// Fallback event for an ambiguous diff when no LLM is configured or
    /// reachable — logged instead of failing or guessing (spec §05).
    public static func unresolvedChangeEvent(fileName: String) -> LogEvent {
        LogEvent(
            file: fileName, event: .unresolved, taskID: "-", sectionPath: nil,
            text: "cambio sin interpretar", source: .freeEdit, interpretedBy: .heuristic
        )
    }

    private static func flatten(_ document: ListoDocument) -> [FlatTask] {
        func walk(_ sections: [ListoSection], trail: [String]) -> [FlatTask] {
            var result: [FlatTask] = []
            for section in sections {
                let path = trail + [section.title]
                for task in section.tasks {
                    result.append(FlatTask(task: task, sectionPath: path, parentText: nil))
                    for sub in task.subtasks {
                        result.append(FlatTask(task: sub, sectionPath: path, parentText: task.text))
                    }
                }
                result.append(contentsOf: walk(section.subsections, trail: path))
            }
            return result
        }
        return walk(document.sections, trail: []) + document.looseTasks.map {
            FlatTask(task: $0, sectionPath: [], parentText: nil)
        }
    }

    /// Normalized Levenshtein similarity in [0, 1]; 1 = identical.
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let la = Array(a), lb = Array(b)
        if la.isEmpty || lb.isEmpty { return 0 }
        var previous = Array(0...lb.count)
        var current = [Int](repeating: 0, count: lb.count + 1)
        for i in 1...la.count {
            current[0] = i
            for j in 1...lb.count {
                let cost = la[i - 1] == lb[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        let distance = previous[lb.count]
        let maxLen = max(la.count, lb.count)
        return 1 - (Double(distance) / Double(maxLen))
    }
}
