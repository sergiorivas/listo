import SwiftUI

/// The task count next to a section's title (Kanban column, Kanban subgroup,
/// Outline heading). Shown even at 0 so an empty section reads as empty
/// rather than as missing a badge.
struct SectionCountBadge: View {
    @ObservedObject private var settings = AppSettings.shared
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(settings.font(.caption, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .help(String(format: L("section.taskCount", "%d tareas"), count))
            .accessibilityLabel(String(format: L("section.taskCount", "%d tareas"), count))
    }
}
