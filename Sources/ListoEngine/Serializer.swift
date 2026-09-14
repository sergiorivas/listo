import Foundation

/// Renders a `ListoDocument` tree back to markdown text. Used to create new
/// files and as the fallback when an LLM conflict-merge (spec §03) returns a
/// freshly reconciled tree rather than a line patch. In-app edits (§03 "Modo
/// App") go through `ListoEditor` instead, which patches the existing text
/// in place so the file is never rewritten wholesale.
public enum ListoSerializer {

    public static func serialize(_ document: ListoDocument) -> String {
        var lines: [String] = []
        for task in document.looseTasks {
            lines.append(contentsOf: serialize(task: task, level: 0))
        }
        for (i, section) in document.sections.enumerated() {
            lines.append(contentsOf: serialize(section: section))
            if i < document.sections.count - 1 {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func serialize(section: ListoSection) -> [String] {
        var lines: [String] = [String(repeating: "#", count: section.level) + " " + section.title]
        for task in section.tasks {
            lines.append(contentsOf: serialize(task: task, level: 0))
        }
        for sub in section.subsections {
            lines.append(contentsOf: serialize(section: sub))
        }
        return lines
    }

    private static func serialize(task: ListoTask, level: Int) -> [String] {
        let indent = String(repeating: "  ", count: level)
        let box = task.state == .done ? "[x]" : "[ ]"
        var lines = ["\(indent)- \(box) \(task.text)"]
        if let note = task.note {
            // `task.note` is stored dedented (see ListoParser.finalizeNote);
            // re-add the one indent unit that marks it as this task's note.
            let noteIndent = indent + "  "
            lines.append(contentsOf: note.components(separatedBy: "\n").map { $0.isEmpty ? "" : noteIndent + $0 })
        }
        for sub in task.subtasks {
            lines.append(contentsOf: serialize(task: sub, level: level + 1))
        }
        return lines
    }
}
