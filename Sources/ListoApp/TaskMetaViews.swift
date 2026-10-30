import SwiftUI
import ListoEngine

extension DueStatus {
    var color: Color {
        switch self {
        case .overdue: return .red
        case .today: return .orange
        case .soon, .later: return .secondary
        }
    }

    var label: String {
        switch self {
        case .overdue: return L("due.overdue", "Vencida")
        case .today: return L("due.today", "Hoy")
        case .soon, .later: return L("due.date", "Fecha límite")
        }
    }
}

/// The due-date and tag chips on a task row, shown *instead of* the raw
/// `@2026-11-03` / `#tag` tokens (only Free Mode and the title field show
/// those). A tag is a button: it filters the board down to that tag.
struct TaskMetaBadges: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared
    let task: ListoTask

    var body: some View {
        let metadata = task.metadata
        let done = task.state == .done
        if let due = metadata.due {
            let status = DueStatus(due: due, today: TaskDueDate(date: Date()))
            // A finished task isn't late any more.
            let shown = done ? DueStatus.later : status
            // Overdue isn't colour alone: a warning glyph and heavier weight too.
            Label(
                due.date().formatted(.dateTime.month(.abbreviated).day()),
                systemImage: shown == .overdue ? "exclamationmark.triangle.fill" : "calendar"
            )
                .font(settings.font(.caption, weight: shown == .overdue ? .semibold : .regular))
                .foregroundStyle(shown.color)
                .lineLimit(1)
                .fixedSize()
                .opacity(done ? 0.5 : 1)
                .help(done ? L("due.date", "Fecha límite") : status.label)
                .accessibilityLabel("\(done ? L("due.date", "Fecha límite") : status.label) \(due.date().formatted(date: .long, time: .omitted))")
        }
        ForEach(metadata.tags, id: \.self) { tag in
            Button {
                controller.filter.tag = tag
            } label: {
                Text("#\(tag)")
                    .font(settings.font(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .opacity(done ? 0.5 : 1)
            .help(String(format: L("tag.filterBy", "Filtrar por #%@"), tag))
        }
    }
}

/// The "Due date" submenu of a task's right-click menu, next to Priority.
struct DueMenu: View {
    @ObservedObject var controller: DocumentController
    let task: ListoTask

    var body: some View {
        Menu {
            Button(L("due.today", "Hoy")) { set(offset: 0) }
            Button(L("due.tomorrow", "Mañana")) { set(offset: 1) }
            Button(L("due.nextWeek", "En una semana")) { set(offset: 7) }
            Button(L("due.choose", "Elegir fecha…")) {
                controller.duePickerTaskID = DuePickerTarget(id: task.id)
            }
            if task.dueDate != nil {
                Divider()
                Button(L("due.clear", "Quitar fecha")) { set(offset: nil) }
            }
        } label: {
            Label(L("due.menu", "Fecha límite"), systemImage: "calendar")
        }
    }

    private func set(offset: Int?) {
        let due = offset.map { TaskDueDate(date: Date()).adding(days: $0) }
        let text = TaskMetadata.settingDue(due, in: task.text)
        controller.rename(taskID: task.id, newText: text)
    }
}

/// Which task the due-date sheet is for (`sheet(item:)` needs an
/// `Identifiable`).
struct DuePickerTarget: Identifiable {
    let id: UUID
}

/// The calendar behind the Due date menu's "Choose date…": any day, not
/// just the menu's Today/Tomorrow/In a week.
struct DueDatePickerSheet: View {
    @ObservedObject var controller: DocumentController
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    private var task: ListoTask? {
        controller.document.allTasksRecursive.first { $0.id == taskID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task?.displayTitle ?? "")
                .font(.headline)
                .lineLimit(2)
            DatePicker(L("due.menu", "Fecha límite"), selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if task?.dueDate != nil {
                    Button(L("due.clear", "Quitar fecha")) { save(nil) }
                }
                Spacer()
                Button(L("note.cancel", "Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("due.set", "Poner fecha")) { save(TaskDueDate(date: date)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear { date = task?.dueDate?.date() ?? Date() }
    }

    private func save(_ due: TaskDueDate?) {
        if let task {
            controller.rename(taskID: task.id, newText: TaskMetadata.settingDue(due, in: task.text))
        }
        dismiss()
    }
}

/// Toolbar menu for the criteria beyond the search text.
struct FilterMenu: View {
    @ObservedObject var controller: DocumentController

    var body: some View {
        Menu {
            Picker(L("filter.state", "Estado"), selection: $controller.filter.state) {
                Text(L("filter.state.any", "Todas")).tag(TaskFilter.State.any)
                Text(L("filter.state.open", "Abiertas")).tag(TaskFilter.State.open)
                Text(L("filter.state.done", "Hechas")).tag(TaskFilter.State.done)
            }
            .pickerStyle(.inline)

            Picker(L("filter.priority", "Prioridad mínima"), selection: $controller.filter.minPriority) {
                ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { level in
                    Text(level == .none ? L("filter.priority.any", "Cualquiera") : "\(level.label)  \(level.marker)").tag(level)
                }
            }

            Picker(L("filter.due", "Vencimiento"), selection: $controller.filter.due) {
                Text(L("filter.due.any", "Cualquiera")).tag(TaskFilter.Due.any)
                Text(L("filter.due.overdue", "Vencidas")).tag(TaskFilter.Due.overdue)
                Text(L("filter.due.today", "Hoy")).tag(TaskFilter.Due.today)
                Text(L("filter.due.thisWeek", "Esta semana")).tag(TaskFilter.Due.thisWeek)
                Text(L("filter.due.hasDate", "Con fecha")).tag(TaskFilter.Due.hasDate)
                Text(L("filter.due.noDate", "Sin fecha")).tag(TaskFilter.Due.noDate)
            }

            let tags = controller.document.tagCounts
            Picker(L("filter.tag", "Etiqueta"), selection: $controller.filter.tag) {
                Text(L("filter.priority.any", "Cualquiera")).tag(String?.none)
                ForEach(tags, id: \.tag) { entry in
                    Text("#\(entry.tag)  (\(entry.count))").tag(String?.some(entry.tag))
                }
            }

            if controller.filter.isActive {
                Divider()
                Button(L("filter.clear", "Quitar filtros")) { controller.filter = TaskFilter() }
            }
        } label: {
            Label(L("filter.title", "Filtrar tareas"), systemImage: controller.filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .help(L("filter.title", "Filtrar tareas"))
    }
}
