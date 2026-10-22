import SwiftUI
import ListoEngine

/// Active filters as removable chips under the toolbar, plus how many tasks
/// they leave — so a hidden task is never a mystery. Only drawn while a
/// filter is active.
struct FilterBar: View {
    @ObservedObject var controller: DocumentController
    @ObservedObject private var settings = AppSettings.shared

    private struct Chip: Identifiable {
        let id: String
        let title: String
        let remove: () -> Void
    }

    private var chips: [Chip] {
        var result: [Chip] = []
        let filter = controller.filter
        let trimmed = filter.query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(Chip(id: "query", title: String(format: L("filter.search", "Búsqueda: %@"), trimmed)) {
                controller.filter.query = ""
            })
        }
        switch filter.state {
        case .any: break
        case .open: result.append(Chip(id: "state", title: L("filter.state.open", "Abiertas")) { controller.filter.state = .any })
        case .done: result.append(Chip(id: "state", title: L("filter.state.done", "Hechas")) { controller.filter.state = .any })
        }
        if filter.minPriority != .none {
            result.append(Chip(id: "priority", title: "≥ \(filter.minPriority.label) \(filter.minPriority.marker)") {
                controller.filter.minPriority = .none
            })
        }
        if let tag = filter.tag {
            result.append(Chip(id: "tag", title: "#\(tag)") { controller.filter.tag = nil })
        }
        let dueTitle: String? = switch filter.due {
        case .any: nil
        case .overdue: L("filter.due.overdue", "Vencidas")
        case .today: L("filter.due.today", "Hoy")
        case .thisWeek: L("filter.due.thisWeek", "Esta semana")
        case .hasDate: L("filter.due.hasDate", "Con fecha")
        case .noDate: L("filter.due.noDate", "Sin fecha")
        }
        if let dueTitle {
            result.append(Chip(id: "due", title: dueTitle) { controller.filter.due = .any })
        }
        return result
    }

    var body: some View {
        if controller.filter.isActive {
            let shown = controller.filter.displayOrder(in: controller.document).count
            let total = controller.document.allTasksRecursive.count
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    HStack(spacing: 3) {
                        Text(chip.title)
                        Button(action: chip.remove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help(L("filter.chip.remove", "Quitar filtro"))
                        .accessibilityLabel("\(L("filter.chip.remove", "Quitar filtro")): \(chip.title)")
                    }
                    .font(settings.font(.caption))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Button(L("filter.clear", "Quitar filtros")) { controller.filter = TaskFilter() }
                    .buttonStyle(.plain)
                    .font(settings.font(.caption))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 8)
                Text(String(format: L("filter.shown", "%d de %d tareas"), shown, total))
                    .font(settings.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Shown over the board when the active filters hide every task.
struct NoMatchesView: View {
    @ObservedObject var controller: DocumentController

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(L("filter.noMatches", "Ninguna tarea coincide"))
                .font(.headline)
            Text(L("filter.noMatches.hint", "Prueba con otros filtros o límpialos."))
                .foregroundStyle(.secondary)
            Button(L("filter.clear", "Quitar filtros")) { controller.filter = TaskFilter() }
                .padding(.top, 4)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
