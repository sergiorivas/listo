import Foundation
import ListoEngine

/// Where a dragged task may land on the row it hovers, given how far down
/// that row the pointer is. `nil` means the drop is refused there.
enum DropRule {
    /// - Parameter fraction: pointer position down the target row, 0...1.
    /// - Parameter targetShowsSubtasks: the target row has subtasks drawn
    ///   under it, so "below it" visually means "inside it".
    static func placement(
        dragged: ListoTask,
        target: ListoTask,
        in document: ListoDocument,
        fraction: Double,
        targetShowsSubtasks: Bool
    ) -> DropPlacement? {
        guard dragged.id != target.id,
              !dragged.subtasks.contains(where: { $0.id == target.id }),
              let from = document.location(of: dragged),
              let to = document.location(of: target)
        else { return nil }
        let draggedIsTop = from.parent == nil
        let targetIsTop = to.parent == nil

        // Next to the target. Views sort siblings by priority, so inside one
        // section and parent the file order only shows between equal
        // priorities; elsewhere the task changes section or parent, which
        // always shows.
        let canBeSibling = draggedIsTop == targetIsTop
            && (from.section.id != to.section.id
                || from.parent?.id != to.parent?.id
                || dragged.priority == target.priority)
        // Inside the target: only under a top-level task, and a top-level
        // task being nested can't bring a note or subtasks along.
        let canNest = targetIsTop
            && from.parent?.id != target.id
            && (!draggedIsTop || (dragged.subtasks.isEmpty && dragged.note == nil))

        func sibling(_ upper: Bool) -> DropPlacement? { canBeSibling ? (upper ? .before : .after) : nil }

        guard targetIsTop else { return sibling(fraction < 0.5) }
        switch fraction {
        case ..<0.3:
            return sibling(true) ?? (canNest ? .asSubtask : nil)
        case 0.7...:
            return targetShowsSubtasks
                ? (canNest ? .asSubtask : nil)
                : (sibling(false) ?? (canNest ? .asSubtask : nil))
        default:
            return canNest ? .asSubtask : sibling(fraction < 0.5)
        }
    }
}
