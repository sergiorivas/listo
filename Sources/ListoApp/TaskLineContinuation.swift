import Foundation

/// What Return should do in Free Mode on a task/subtask line: continue the
/// list with a fresh `- [ ] ` at the same indentation, or — on a line that is
/// only an empty checkbox — end the list by clearing that line (the usual
/// Markdown-editor convention, so Return twice gets you out).
enum TaskLineContinuation: Equatable {
    /// Insert a newline followed by this prefix (indentation + `- [ ] `).
    case continueWith(String)
    /// The line is just an empty checkbox: remove it, leaving a blank line.
    case endList
    /// Not a task line (or the cursor is inside the prefix): plain newline.
    case none

    private static let pattern = try! NSRegularExpression(pattern: "^([ \\t]*)- \\[[ xX]\\] ?")

    /// `line` is the current line without its newline; `cursor` is the
    /// caret's offset within it (UTF-16, as `NSTextView` reports it).
    static func resolve(line: String, cursor: Int) -> TaskLineContinuation {
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return .none
        }
        let prefixEnd = match.range.location + match.range.length
        guard cursor >= prefixEnd else { return .none }
        let indent = ns.substring(with: match.range(at: 1))
        let rest = ns.substring(from: prefixEnd)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return .endList
        }
        return .continueWith(indent + "- [ ] ")
    }
}
