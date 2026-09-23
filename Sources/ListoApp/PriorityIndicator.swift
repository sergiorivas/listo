import SwiftUI
import ListoEngine

extension TaskPriority {
    /// Colour of the indicator — the number of marks carries the level on
    /// its own, so this never has to be the only cue.
    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }

    /// `exclamationmark`, `.2`, `.3` — one mark per level, mirroring the
    /// `!`/`!!`/`!!!` written in the file.
    var symbolName: String {
        switch self {
        case .none: return "exclamationmark"
        case .low: return "exclamationmark"
        case .medium: return "exclamationmark.2"
        case .high: return "exclamationmark.3"
        }
    }

    var label: String {
        switch self {
        case .none: return L("priority.none", "Sin prioridad")
        case .low: return L("priority.low", "Baja")
        case .medium: return L("priority.medium", "Media")
        case .high: return L("priority.high", "Alta")
        }
    }
}

/// The priority indicator on a task row. Shown *instead of* the raw `!`
/// marker (which only Free Mode displays); renders nothing for `.none`.
struct PriorityBadge: View {
    @ObservedObject private var settings = AppSettings.shared
    let priority: TaskPriority
    /// A completed task keeps its indicator, just muted.
    var dimmed = false

    var body: some View {
        if priority != .none {
            Image(systemName: priority.symbolName)
                .font(settings.font(.caption, weight: .bold))
                .foregroundStyle(priority.color)
                .opacity(dimmed ? 0.4 : 1)
                .contentTransition(.symbolEffect(.replace))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .help(priority.label)
                .accessibilityLabel(priority.label)
        }
    }
}

/// The "Priority" submenu of a task's right-click menu, shared by Kanban and
/// Outline: the current level is checked, picking another sets it, and
/// "No priority" clears it.
struct PriorityMenu: View {
    @ObservedObject var controller: DocumentController
    let task: ListoTask

    var body: some View {
        Menu {
            ForEach([TaskPriority.high, .medium, .low, .none], id: \.self) { level in
                Button {
                    controller.setPriority(taskID: task.id, priority: level)
                } label: {
                    if level == task.priority {
                        Label(title(for: level), systemImage: "checkmark")
                    } else {
                        Text(title(for: level))
                    }
                }
            }
        } label: {
            Label(L("task.priority", "Prioridad"), systemImage: "exclamationmark.3")
        }
    }

    private func title(for level: TaskPriority) -> String {
        level == .none ? level.label : "\(level.label)  \(level.marker)"
    }
}
