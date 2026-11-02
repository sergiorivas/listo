import Foundation

/// Appends `LogEvent`s to the per-document JSONL log file (spec §05), and
/// reads them back for the in-app log view.
///
/// The log lives as a hidden sidecar next to the source file
/// (`.<name>.listo.jsonl`) so it travels with the document without cluttering
/// the visible file listing.
public final class LogWriter {
    public let logFileURL: URL
    private let queue = DispatchQueue(label: "listo.logwriter")

    public init(documentURL: URL) {
        self.logFileURL = LogWriter.logFileURL(for: documentURL)
    }

    public static func logFileURL(for documentURL: URL) -> URL {
        let dir = documentURL.deletingLastPathComponent()
        let base = documentURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(".\(base).listo.jsonl")
    }

    @discardableResult
    public func append(_ event: LogEvent) throws -> LogEvent {
        let encoder = JSONEncoder()
        var data = try encoder.encode(event)
        data.append(0x0A)
        try queue.sync {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
        }
        return event
    }

    /// Events decoded so far, the byte offset just past the last complete
    /// line they came from, and the file they came from (inode), so
    /// `readAll` only decodes what was appended since the previous call.
    private var cachedEvents: [LogEvent] = []
    private var cachedOffset: UInt64 = 0
    private var cachedFileNumber: Int?

    /// Every event in the log, oldest first. Called after every App Mode
    /// action, so it reads incrementally: the log is append-only, and
    /// re-reading and re-decoding the whole (ever-growing) file each time put
    /// avoidable work on the main thread — worse on an iCloud-synced folder.
    /// Falls back to a full read if the file was replaced (new inode) or
    /// shrank. A trailing line without its newline yet (another writer
    /// mid-append) is left for the next call.
    public func readAll() throws -> [LogEvent] {
        try queue.sync {
            let path = logFileURL.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                cachedEvents = []; cachedOffset = 0; cachedFileNumber = nil
                return []
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.intValue
            if fileNumber != cachedFileNumber || size < cachedOffset {
                cachedEvents = []; cachedOffset = 0; cachedFileNumber = fileNumber
            }
            guard size > cachedOffset else { return cachedEvents }

            let handle = try FileHandle(forReadingFrom: logFileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: cachedOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return cachedEvents }
            let complete = data[data.startIndex...lastNewline]

            let decoder = JSONDecoder()
            for line in complete.split(separator: 0x0A) {
                if let event = try? decoder.decode(LogEvent.self, from: Data(line)) {
                    cachedEvents.append(event)
                }
            }
            cachedOffset += UInt64(complete.count)
            return cachedEvents
        }
    }
}

/// Renders log events as human-readable lines, e.g. `moved: "Migrar base de
/// datos" from ahora → mas tarde`. Kept separate from `LogEvent` itself so
/// the wire schema stays the 8 documented fields (plus `reverts`, only on
/// undo/redo events) with no display-only baggage.
///
/// Always English regardless of the app's display language — the log is
/// meant to be a stable, greppable record (and possibly read by tooling),
/// not part of the localized UI.
public enum LogFormatter {
    public static func describe(_ event: LogEvent, previousText: String? = nil) -> String {
        switch event.event {
        case .created:
            let section = sectionLabel(event.sectionPath) ?? ""
            return "created: \"\(event.text)\"" + (section.isEmpty ? "" : " in \(section)")
        case .completed:
            return "completed: \"\(event.text)\""
        case .reopened:
            return "reopened: \"\(event.text)\""
        case .edited:
            if let previousText, previousText != event.text {
                return "edited: \"\(previousText)\" → \"\(event.text)\""
            }
            return "edited: \"\(event.text)\""
        case .movedSection:
            if case let .move(from, to)? = event.sectionPath {
                return "moved: \"\(event.text)\" from \(from.joined(separator: " / ")) → \(to.joined(separator: " / "))"
            }
            return "moved: \"\(event.text)\""
        case .reindented:
            return "\"\(event.text)\" changed indentation level"
        case .reordered:
            return "\"\(event.text)\" changed position"
        case .split:
            return "split into its subtasks: \"\(event.text)\""
        case .grouped:
            return "grouped tasks into: \"\(event.text)\""
        case .priorityChanged:
            // `text` carries the new marker as a trailing token when a
            // priority was set, and nothing when it was cleared (see
            // `ListoEditor.setPriority`).
            let (title, priority) = TaskPriority.split(event.text)
            return priority == .none
                ? "priority cleared: \"\(event.text)\""
                : "priority set to \(priority.marker): \"\(title)\""
        case .noteUpdated:
            return "note updated: \"\(event.text)\""
        case .deleted:
            return "deleted: \"\(event.text)\""
        case .undone, .redone:
            // Reads as the action it reverted/re-applied, e.g.
            // `undone — deleted: "Buy milk"`.
            let prefix = event.event == .undone ? "undone" : "redone"
            guard let original = event.reverts else { return "\(prefix): \"\(event.text)\"" }
            var inner = event
            inner.event = original
            return "\(prefix) — " + describe(inner)
        case .unresolved:
            return "unrecognized change (\(event.text))"
        }
    }

    private static func sectionLabel(_ path: LogEvent.SectionPath?) -> String? {
        switch path {
        case .path(let p): return p.joined(separator: " / ")
        case .move(_, let to): return to.joined(separator: " / ")
        case nil: return nil
        }
    }
}
