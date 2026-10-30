import Foundation

/// A calendar day with no time or zone, written in a task title as
/// `@2026-11-03`.
public struct TaskDueDate: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int, calendar: Calendar = .current) {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!
        self.month = c.month!
        self.day = c.day!
    }

    /// Parses `@YYYY-MM-DD` (an impossible date like `@2026-02-31` is not a
    /// due date, just text).
    public init?(token: String, calendar: Calendar = .current) {
        guard token.hasPrefix("@") else { return nil }
        let parts = token.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d, calendar: calendar)
    }

    /// How it is written in the file: `@2026-11-03`.
    public var token: String { String(format: "@%04d-%02d-%02d", year, month, day) }

    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Whole days from `other` to this date: negative when this is earlier.
    public func days(since other: TaskDueDate, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: other.date(calendar: calendar), to: date(calendar: calendar)).day ?? 0
    }

    public func adding(days: Int, calendar: Calendar = .current) -> TaskDueDate {
        TaskDueDate(date: calendar.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: calendar)
    }

    public static func < (a: TaskDueDate, b: TaskDueDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// A date typed in words — `@today`, `@tomorrow`, `@fri`, `@3d`, `@2w`,
    /// or their Spanish forms (`@hoy`, `@mañana`, `@vie`, `@2s`) — resolved
    /// against `today`. A weekday is the next one strictly after today, so
    /// `@fri` typed on a Friday means a week later. Case and accents are
    /// ignored. Anything else (including an absolute `@2026-11-03`) is `nil`.
    public init?(relativeToken token: String, today: TaskDueDate, calendar: Calendar = .current) {
        guard token.hasPrefix("@") else { return nil }
        let word = token.dropFirst().folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let offset: Int
        if let days = Self.namedOffsets[word] {
            offset = days
        } else if let weekday = Self.weekdays[word] {
            let current = calendar.component(.weekday, from: today.date(calendar: calendar))
            let ahead = (weekday - current + 7) % 7
            offset = ahead == 0 ? 7 : ahead
        } else if let unit = word.last, let multiplier = Self.unitDays[unit],
                  let count = Int(word.dropLast()), (1...999).contains(count) {
            offset = count * multiplier
        } else {
            return nil
        }
        self = today.adding(days: offset, calendar: calendar)
    }

    private static let namedOffsets: [String: Int] = [
        // No `@tom`/`@tod` short forms: those read as people's names.
        "today": 0, "hoy": 0,
        "tomorrow": 1, "tmr": 1, "manana": 1,
    ]

    /// `Calendar.component(.weekday)` numbering: Sunday = 1.
    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "dom": 1, "domingo": 1,
        "mon": 2, "monday": 2, "lun": 2, "lunes": 2,
        "tue": 3, "tues": 3, "tuesday": 3, "mar": 3, "martes": 3,
        "wed": 4, "wednesday": 4, "mie": 4, "miercoles": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "jue": 5, "jueves": 5,
        "fri": 6, "friday": 6, "vie": 6, "viernes": 6,
        "sat": 7, "saturday": 7, "sab": 7, "sabado": 7,
    ]

    /// `@3d` days, `@2w` (or Spanish `@2s`, semanas) weeks.
    private static let unitDays: [Character: Int] = ["d": 1, "w": 7, "s": 7]
}

/// Where a due date stands relative to a reference day.
public enum DueStatus: Sendable {
    case overdue, today, soon, later

    /// `soon` is within the coming week.
    public init(due: TaskDueDate, today: TaskDueDate, calendar: Calendar = .current) {
        switch due.days(since: today, calendar: calendar) {
        case ..<0: self = .overdue
        case 0: self = .today
        case 1...7: self = .soon
        default: self = .later
        }
    }
}

/// What a task's title carries besides its words: an optional due date
/// (`@2026-11-03`) and `#tags`. They stay in `ListoTask.text` exactly as
/// typed — unlike the priority marker, which is split off the title — so
/// every writer, the differ and the log keep them for free; this only reads
/// them back out so the views can show badges instead of raw tokens.
public struct TaskMetadata: Equatable, Sendable {
    /// The title with the due date and tags removed.
    public var displayTitle: String
    public var due: TaskDueDate?
    /// Lowercased, without the `#`, in order of appearance, no duplicates.
    public var tags: [String]

    public init(_ text: String, calendar: Calendar = .current) {
        var words: [Substring] = []
        var due: TaskDueDate?
        var tags: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            if due == nil, let parsed = TaskDueDate(token: String(word), calendar: calendar) {
                due = parsed
            } else if let tag = Self.tag(in: word) {
                if !tags.contains(tag) { tags.append(tag) }
            } else {
                words.append(word)
            }
        }
        let title = words.joined(separator: " ")
        // A title that is nothing but tokens keeps showing them rather than
        // rendering as an empty row.
        self.displayTitle = title.isEmpty ? text.trimmingCharacters(in: .whitespaces) : title
        self.due = due
        self.tags = tags
    }

    /// `#work` → `work`. Must start with a letter, so `#1` (an issue
    /// number) and a bare `#` stay plain text.
    static func tag(in word: Substring) -> String? {
        guard word.hasPrefix("#"), let first = word.dropFirst().first, first.isLetter else { return nil }
        let body = word.dropFirst()
        guard body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return body.lowercased()
    }

    /// `text` with its due date replaced by `due` (appended at the end), or
    /// removed when `due` is `nil`. Everything else is left as typed.
    public static func settingDue(_ due: TaskDueDate?, in text: String, calendar: Calendar = .current) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let idx = words.firstIndex(where: { TaskDueDate(token: $0, calendar: calendar) != nil }) {
            words.remove(at: idx)
        }
        if let due { words.append(due.token) }
        return words.joined(separator: " ")
    }

    /// `text` with every date typed in words (`@tomorrow`, `@fri`, `@3d`,
    /// see `TaskDueDate(relativeToken:)`) rewritten as the absolute
    /// `@YYYY-MM-DD` it means today, so the file holds a date that stays
    /// put. Spacing and every other word are left exactly as typed.
    public static func resolvingRelativeDates(in text: String, today: TaskDueDate, calendar: Calendar = .current) -> String {
        guard text.contains("@") else { return text }
        var result = ""
        var word = ""
        func flush() {
            result += TaskDueDate(relativeToken: word, today: today, calendar: calendar)?.token ?? word
            word = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                result.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return result
    }
}

extension ListoTask {
    public var metadata: TaskMetadata { TaskMetadata(text) }
    public var dueDate: TaskDueDate? { metadata.due }
    public var tags: [String] { metadata.tags }
    /// The title as the views show it: no `@date`, no `#tags`.
    public var displayTitle: String { metadata.displayTitle }
}

extension ListoDocument {
    /// Every tag used in the document with how many tasks carry it, most
    /// used first (ties alphabetical).
    public var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for task in allTasksRecursive {
            for tag in task.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}
