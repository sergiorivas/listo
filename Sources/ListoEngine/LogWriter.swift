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

/// Renders log events as the human-readable lines shown in spec §05's table,
/// e.g. `movida: "Migrar base de datos" de ahora → mas tarde`. Kept separate
/// from `LogEvent` itself so the wire schema stays exactly the 8 documented
/// fields with no display-only baggage.
public enum LogFormatter {
    public static func describe(_ event: LogEvent, previousText: String? = nil) -> String {
        switch event.event {
        case .created:
            let section = sectionLabel(event.sectionPath) ?? ""
            return "creada: \"\(event.text)\"" + (section.isEmpty ? "" : " en \(section)")
        case .completed:
            return "completada: \"\(event.text)\""
        case .reopened:
            return "reabierta: \"\(event.text)\""
        case .edited:
            if let previousText, previousText != event.text {
                return "editada: \"\(previousText)\" → \"\(event.text)\""
            }
            return "editada: \"\(event.text)\""
        case .movedSection:
            if case let .move(from, to)? = event.sectionPath {
                return "movida: \"\(event.text)\" de \(from.joined(separator: " / ")) → \(to.joined(separator: " / "))"
            }
            return "movida: \"\(event.text)\""
        case .reindented:
            return "\"\(event.text)\" cambió de nivel de indentación"
        case .noteUpdated:
            return "notas editadas: \"\(event.text)\""
        case .deleted:
            return "eliminada: \"\(event.text)\""
        case .unresolved:
            return "cambio sin interpretar (sin clave de API configurada)"
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
