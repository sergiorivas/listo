import AppKit
import Foundation
import SwiftUI
import ListoEngine

extension DocumentController {
    /// Moves selection to the task immediately before (`direction: -1`) or
    /// after (`direction: +1`) the current selection — ↑/↓ arrow
    /// navigation. A no-op if nothing's selected or the move would go past
    /// either end, same as indent/outdent at their limits.
    ///
    /// Scoped to the current view style: Outline renders every section as
    /// one continuous vertical list, so navigation spans the whole
    /// document; Kanban renders each top-level section as its own
    /// side-by-side column, so navigation stays within the selected task's
    /// column — crossing into a different column on ↓ would jump somewhere
    /// spatially unrelated to where the arrow key points.
    ///
    /// `keepEditing`: pass `true` when called from a task's own title field
    /// (↑/↓ while typing) to move edit focus along with the selection, not
    /// just the selection itself — mirrors how Return/Tab already keep you
    /// typing across the task they create or re-indent.
    func selectAdjacent(direction: Int, keepEditing: Bool) {
        guard let currentID = selectedTaskID,
              let newID = adjacentTaskID(to: currentID, direction: direction) else { return }
        if keepEditing, discardIfBlank(taskID: currentID) {
            // The delete can re-id the neighbor (content-derived ids) —
            // only follow it if it still resolves.
            guard document.allTasksRecursive.contains(where: { $0.id == newID }) else { return }
        }
        selectedTaskID = newID
        if keepEditing { editingTaskID = newID }
    }

    /// Every task in the current view style's navigation order (see
    /// `selectAdjacent`) that contains `taskID` — the whole document in
    /// Outline, the task's own column in Kanban.
    func navigationOrder(containing taskID: UUID) -> [UUID]? {
        switch viewStyle {
        case .outline:
            return filter.displayOrder(in: document).map(\.id)
        case .kanban:
            return document.sections.first(where: { section in
                section.allTasksRecursive.contains { $0.id == taskID }
            }).map { filter.displayOrder(in: $0).map(\.id) }
        }
    }

    // MARK: - Multi-selection

    func isSelected(_ taskID: UUID) -> Bool {
        selectedTaskID == taskID || multiSelectedIDs.contains(taskID)
    }

    /// What an action invoked on `taskID` acts on: the whole multi-selection
    /// (in display order) when `taskID` is part of it, else just that task.
    func targets(for taskID: UUID) -> [UUID] {
        guard multiSelectedIDs.contains(taskID),
              let order = navigationOrder(containing: taskID) else { return [taskID] }
        return order.filter(multiSelectedIDs.contains)
    }

    /// ⇧↑ / ⇧↓: extends (or shrinks, back toward the anchor) the selection by
    /// the next task *of the same level* — a selection that starts on a task
    /// only ever holds tasks, one that starts on a subtask only subtasks.
    func extendSelection(direction: Int) {
        guard mode == .app, let cursor = selectedTaskID,
              let order = navigationOrder(containing: cursor) else { return }
        let level = depth(of: cursor)
        let sameLevel = order.filter { depth(of: $0) == level }
        let anchor = selectionAnchorID.flatMap { !multiSelectedIDs.isEmpty && sameLevel.contains($0) ? $0 : nil } ?? cursor
        guard let cursorIdx = sameLevel.firstIndex(of: cursor),
              let anchorIdx = sameLevel.firstIndex(of: anchor),
              sameLevel.indices.contains(cursorIdx + direction) else { return }
        let newIdx = cursorIdx + direction
        let range = min(anchorIdx, newIdx)...max(anchorIdx, newIdx)
        keepsMultiSelection = true
        multiSelectedIDs = range.count > 1 ? Set(sameLevel[range]) : []
        selectedTaskID = sameLevel[newIdx]
        keepsMultiSelection = false
        selectionAnchorID = range.count > 1 ? anchor : nil
    }

    func depth(of taskID: UUID) -> Int {
        document.allTasksRecursive.first { $0.id == taskID }.map { document.depth(of: $0) } ?? 0
    }

    /// Runs `action` on each of `ids` as one undo step, then re-points the
    /// selection (cursor, anchor, multi-selection) at wherever those tasks
    /// ended up.
    ///
    /// - Parameter follow: the action gives its task a new id
    ///   (`lastActionTaskID`), as indent/outdent/move/reorder do.
    /// - Parameter silencing: errors that are just "can't go further" for one
    ///   task; that task is skipped and the rest carry on.
    /// - Returns: whether at least one action ran.
    @discardableResult
    func performBatch(
        _ ids: [UUID],
        follow: Bool = false,
        silencing: (ListoEditorError) -> Bool = { _ in false },
        _ action: (ListoEditor, UUID) throws -> Void
    ) -> Bool {
        var newIDs: [UUID: UUID] = [:]
        var ran = false
        do {
            try editor.performBatch {
                for id in ids {
                    do {
                        try action(editor, id)
                        ran = true
                        newIDs[id] = follow ? (editor.lastActionTaskID ?? id) : id
                    } catch let error as ListoEditorError where silencing(error) {
                        newIDs[id] = id
                    }
                }
            }
        } catch {
            errorMessage = "\(error)"
        }
        guard ran else { return false }
        syncDocumentText()
        withAnimation(Motion.snappy) {
            document = editor.document
            reselect(afterBatch: ids, newIDs: newIDs)
        }
        refreshLog()
        saveIfPossible()
        return ran
    }

    func reselect(afterBatch ids: [UUID], newIDs: [UUID: UUID]) {
        let live = Set(document.allTasksRecursive.map(\.id))
        func follow(_ id: UUID?) -> UUID? { id.flatMap { newIDs[$0] ?? $0 }.flatMap { live.contains($0) ? $0 : nil } }
        let remaining = ids.compactMap { follow($0) }
        let cursor = follow(selectedTaskID) ?? remaining.last
        let anchor = follow(selectionAnchorID) ?? remaining.first
        keepsMultiSelection = true
        multiSelectedIDs = remaining.count > 1 ? Set(remaining) : []
        selectedTaskID = remaining.count > 1 ? cursor : remaining.first
        keepsMultiSelection = false
        selectionAnchorID = remaining.count > 1 ? anchor : nil
        if let id = editingTaskID, !live.contains(id) { editingTaskID = nil }
    }

    /// The task next to `taskID` in the current view style's navigation
    /// order (see `selectAdjacent`), or `nil` past either end.
    func adjacentTaskID(to taskID: UUID, direction: Int) -> UUID? {
        guard let orderedIDs = navigationOrder(containing: taskID),
              let idx = orderedIDs.firstIndex(of: taskID) else { return nil }
        let newIdx = idx + direction
        return orderedIDs.indices.contains(newIdx) ? orderedIDs[newIdx] : nil
    }
}
