import Foundation

/// The JSONL log schema from spec §05 — one JSON object per line, one log
/// file per observed document.
public struct LogEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        case created
        case completed
        case reopened
        case edited
        case movedSection = "moved_section"
        case reindented
        case noteUpdated = "note_updated"
        case deleted
        /// An ambiguous Modo Libre diff with no LLM available to interpret it
        /// (no API key configured, or offline) — logged instead of failing
        /// silently or guessing wrong (spec §05).
        case unresolved
    }

    public enum Source: String, Codable {
        case app
        case freeEdit = "free_edit"
    }

    public enum InterpretedBy: String, Codable {
        case userAction = "user_action"
        case heuristic
        case llm
    }

    /// Either a plain section path (`["ahora"]`) or, for `moved_section`
    /// events, a `{from, to}` pair — matches the two shapes shown in spec §05.
    public enum SectionPath: Equatable {
        case path([String])
        case move(from: [String], to: [String])
    }

    public var ts: Date
    public var file: String
    public var event: Kind
    public var taskID: String
    public var sectionPath: SectionPath?
    public var text: String
    public var source: Source
    public var interpretedBy: InterpretedBy

    public init(
        ts: Date = Date(),
        file: String,
        event: Kind,
        taskID: String,
        sectionPath: SectionPath?,
        text: String,
        source: Source,
        interpretedBy: InterpretedBy
    ) {
        self.ts = ts
        self.file = file
        self.event = event
        self.taskID = taskID
        self.sectionPath = sectionPath
        self.text = text
        self.source = source
        self.interpretedBy = interpretedBy
    }

    private enum CodingKeys: String, CodingKey {
        case ts, file, event
        case taskID = "task_id"
        case sectionPath = "section_path"
        case text, source
        case interpretedBy = "interpreted_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tsString = try c.decode(String.self, forKey: .ts)
        guard let date = LogEvent.isoFormatter.date(from: tsString) else {
            throw DecodingError.dataCorruptedError(forKey: .ts, in: c, debugDescription: "Bad ISO8601 timestamp")
        }
        ts = date
        file = try c.decode(String.self, forKey: .file)
        event = try c.decode(Kind.self, forKey: .event)
        taskID = try c.decode(String.self, forKey: .taskID)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(Source.self, forKey: .source)
        interpretedBy = try c.decode(InterpretedBy.self, forKey: .interpretedBy)
        sectionPath = try c.decodeIfPresent(SectionPath.self, forKey: .sectionPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LogEvent.isoFormatter.string(from: ts), forKey: .ts)
        try c.encode(file, forKey: .file)
        try c.encode(event, forKey: .event)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(text, forKey: .text)
        try c.encode(source, forKey: .source)
        try c.encode(interpretedBy, forKey: .interpretedBy)
        try c.encodeIfPresent(sectionPath, forKey: .sectionPath)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()
}

extension LogEvent.SectionPath: Codable {
    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let plain = try? single.decode([String].self) {
            self = .path(plain)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let from = try c.decode([String].self, forKey: .from)
        let to = try c.decode([String].self, forKey: .to)
        self = .move(from: from, to: to)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .path(let p):
            var single = encoder.singleValueContainer()
            try single.encode(p)
        case .move(let from, let to):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        }
    }
}
