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

    public func readAll() throws -> [LogEvent] {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return [] }
        let text = try String(contentsOf: logFileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LogEvent.self, from: data)
        }
    }
}

/// Renders log events as human-readable lines, e.g. `moved: "Migrar base de
/// datos" from ahora → mas tarde`. Kept separate from `LogEvent` itself so
/// the wire schema stays exactly the 8 documented fields with no
/// display-only baggage.
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
        case .noteUpdated:
            return "note updated: \"\(event.text)\""
        case .deleted:
            return "deleted: \"\(event.text)\""
        case .unresolved:
            return "unrecognized change (no API key configured)"
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
