import SwiftUI
import ListoEngine

/// The title-field editing flow shared by the Kanban and Outline rows: how
/// commit, cancel, Return, Tab/⇧Tab and ↑/↓ behave while a task's title is a
/// live text field. A row builds one from its own state each time it needs it.
@MainActor
struct TitleEditing {
    let controller: DocumentController
    let task: ListoTask
    let isEditing: Bool
    @Binding var text: String

    /// Commits the title if changed, without chaining any further action —
    /// used when editing ends because focus just left the field (a click
    /// elsewhere). Returns whether it renamed.
    ///
    /// Idempotency guard: ending edit mode (clearing `editingTaskID`) can
    /// itself cause `isTextFieldFocused` to flip to false as the field
    /// leaves the view tree, which re-fires the `onChange` and would
    /// otherwise call this a second time — using this same (by-then-stale,
    /// already-renamed-away) `task.id` and blowing up with "task not
    /// found". Guarding on `isEditing` catches that: once `editingTaskID`
    /// has moved on (cleared here, or moved to a different row by
    /// `handleReturn`/`handleTab`), `isEditing` for *this* row is already
    /// false.
    @discardableResult
    func commit() -> Bool {
        guard isEditing else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let renamed = !trimmed.isEmpty && trimmed != task.text
        if renamed {
            controller.rename(taskID: task.id, newText: trimmed)
        } else {
            text = task.text
        }
        controller.editingTaskID = nil
        if trimmed.isEmpty { controller.discardIfBlank(taskID: task.id) }
        return renamed
    }

    func cancel() {
        guard isEditing else { return }
        text = task.text
        controller.editingTaskID = nil
        controller.discardIfBlank(taskID: task.id)
    }

    /// Return: commit whatever was typed, then insert a new empty sibling
    /// (same level — a subtask begets a subtask) right after it and move
    /// edit focus straight there, so typing can continue without
    /// re-clicking. An empty title breaks the chain instead of piling up
    /// blank tasks — same as clicking away.
    func handleReturn() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            cancel()
            return
        }
        if trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        }
        controller.insertSiblingAndEdit(afterTaskID: controller.editingTaskID ?? task.id)
        // The sibling just inserted is blank, and when *this* row was itself
        // a blank one its id is the very id the new blank gets — so SwiftUI
        // keeps this view (and its `text`) for it, and neither `.onAppear`
        // nor `.onChange(of: isEditing)` fires (editing goes X -> X within
        // one event). Clear the field by hand or it shows what was just typed.
        text = ""
    }

    /// Tab/⇧Tab: commit whatever was typed, then indent/outdent — following
    /// onto whatever new id the commit gave the task, via `controller.
    /// editingTaskID` (`perform(followSelectionFrom:)` keeps it current) —
    /// and stay in edit mode on the row that results, instead of dropping
    /// back to merely-selected like a stray Tab keystroke used to.
    func handleTab(outdent: Bool) {
        renameIfChanged()
        let anchorID = controller.editingTaskID ?? task.id
        if outdent {
            controller.outdent(taskID: anchorID)
        } else {
            controller.indent(taskID: anchorID)
        }
    }

    /// ↑/↓: commit whatever was typed, then move both selection and edit
    /// focus to the previous/next task — reads `controller.selectedTaskID`
    /// itself (already the post-rename id) rather than needing an
    /// `anchorID` like `handleTab` does.
    func handleVerticalNav(direction: Int) {
        renameIfChanged()
        controller.selectAdjacent(direction: direction, keepEditing: true)
    }

    private func renameIfChanged() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != task.text {
            controller.rename(taskID: task.id, newText: trimmed)
        }
    }
}
