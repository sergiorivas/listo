import XCTest
import ListoEngine
@testable import ListoApp

@MainActor
final class DocumentControllerTests: XCTestCase {
    private func makeController(_ text: String) -> DocumentController {
        let doc = ListoFileDocument()
        doc.text = text
        return DocumentController(fileDocument: doc, fileURL: nil)
    }

    private func task(_ controller: DocumentController, _ text: String) -> ListoTask {
        controller.document.allTasksRecursive.first { $0.text == text }!
    }

    private let list = "# Todo\n\n- [ ] A\n- [ ] B\n- [ ] C\n- [ ] D\n"

    // MARK: - Multi-selection

    func testExtendSelectionBuildsRangeFromAnchor() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.extendSelection(direction: 1)
        c.extendSelection(direction: 1)
        XCTAssertEqual(c.multiSelectedIDs, Set(["A", "B", "C"].map { task(c, $0).id }))
        XCTAssertEqual(c.selectedTaskID, task(c, "C").id)
    }

    func testExtendSelectionShrinksBackTowardAnchor() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.extendSelection(direction: 1)
        c.extendSelection(direction: 1)
        c.extendSelection(direction: -1)
        XCTAssertEqual(c.multiSelectedIDs, Set(["A", "B"].map { task(c, $0).id }))
        c.extendSelection(direction: -1)
        XCTAssertTrue(c.multiSelectedIDs.isEmpty, "back on the anchor is a plain selection")
    }

    func testExtendSelectionStopsAtEdge() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "D").id
        c.extendSelection(direction: 1)
        XCTAssertTrue(c.multiSelectedIDs.isEmpty)
        XCTAssertEqual(c.selectedTaskID, task(c, "D").id)
    }

    func testPlainSelectionAssignmentCollapsesMultiSelection() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.extendSelection(direction: 1)
        c.selectedTaskID = task(c, "D").id
        XCTAssertTrue(c.multiSelectedIDs.isEmpty)
    }

    func testExtendSelectionIgnoredInFreeMode() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.mode = .freeEdit
        c.extendSelection(direction: 1)
        XCTAssertTrue(c.multiSelectedIDs.isEmpty)
    }

    // MARK: - Batch actions

    func testIndentBatchNestsSelectionUnderPrecedingTask() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "B").id
        c.extendSelection(direction: 1)
        c.indent(taskID: c.selectedTaskID!)
        let a = task(c, "A")
        XCTAssertEqual(a.subtasks.map(\.text), ["B", "C"])
        XCTAssertEqual(c.multiSelectedIDs.count, 2, "selection follows the re-id'd tasks")
    }

    func testBatchIsOneUndoStep() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "B").id
        c.extendSelection(direction: 1)
        c.indent(taskID: c.selectedTaskID!)
        c.undo()
        XCTAssertTrue(task(c, "A").subtasks.isEmpty)
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "B", "C", "D"])
    }

    func testDeleteBatchRemovesAllSelected() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "B").id
        c.extendSelection(direction: 1)
        c.delete(taskID: c.selectedTaskID!)
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "D"])
    }

    func testSetPriorityBatchAppliesToEverySelectedTask() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.extendSelection(direction: 1)
        c.setPriority(taskID: c.selectedTaskID!, priority: .high)
        XCTAssertEqual(task(c, "A").priority, .high)
        XCTAssertEqual(task(c, "B").priority, .high)
        XCTAssertEqual(task(c, "C").priority, TaskPriority.none)
    }

    // MARK: - Blank tasks

    func testDiscardIfBlankDeletesEmptyTask() {
        let c = makeController("# Todo\n\n- [ ] A\n- [ ] \n")
        let blank = c.document.sections[0].tasks[1]
        XCTAssertTrue(c.discardIfBlank(taskID: blank.id))
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A"])
    }

    func testDiscardIfBlankKeepsTaskWithText() {
        let c = makeController(list)
        XCTAssertFalse(c.discardIfBlank(taskID: task(c, "A").id))
        XCTAssertEqual(c.document.sections[0].tasks.count, 4)
    }

    func testDiscardIfBlankKeepsBlankTaskWithSubtasks() {
        let c = makeController("# Todo\n\n- [ ] \n  - [ ] child\n")
        let blank = c.document.sections[0].tasks[0]
        XCTAssertFalse(c.discardIfBlank(taskID: blank.id))
        XCTAssertEqual(c.document.sections[0].tasks.count, 1)
    }

    func testDeleteEmptyMovesSelectionToPreviousTask() {
        let c = makeController("# Todo\n\n- [ ] A\n- [ ] \n")
        let blank = c.document.sections[0].tasks[1]
        c.selectedTaskID = blank.id
        XCTAssertTrue(c.deleteEmpty(taskID: blank.id, keepEditing: false))
        XCTAssertEqual(c.selectedTaskID, task(c, "A").id)
        XCTAssertNil(c.editingTaskID)
    }

    func testDeleteEmptyRefusesTaskWithNote() {
        let c = makeController("# Todo\n\n- [ ] \n  a note\n")
        let blank = c.document.sections[0].tasks[0]
        XCTAssertFalse(c.deleteEmpty(taskID: blank.id, keepEditing: false))
        XCTAssertEqual(c.document.sections[0].tasks.count, 1)
    }

    // MARK: - Navigation & history

    func testSelectAdjacentStaysWithinKanbanColumn() {
        let c = makeController("# One\n\n- [ ] A\n\n# Two\n\n- [ ] B\n")
        c.viewStyle = .kanban
        c.selectedTaskID = task(c, "A").id
        c.selectAdjacent(direction: 1, keepEditing: false)
        XCTAssertEqual(c.selectedTaskID, task(c, "A").id)
        c.viewStyle = .outline
        c.selectAdjacent(direction: 1, keepEditing: false)
        XCTAssertEqual(c.selectedTaskID, task(c, "B").id)
    }

    func testUndoRedoRoundTripsToggle() {
        let c = makeController(list)
        c.toggle(taskID: task(c, "A").id)
        XCTAssertEqual(task(c, "A").state, .done)
        c.undo()
        XCTAssertEqual(task(c, "A").state, .open)
        c.redo()
        XCTAssertEqual(task(c, "A").state, .done)
    }

    func testInsertSiblingAndEditAddsBlankAfterTaskAndStartsEditing() {
        let c = makeController(list)
        c.insertSiblingAndEdit(afterTaskID: task(c, "A").id)
        XCTAssertNotNil(c.editingTaskID)
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "", "B", "C", "D"])
    }

    // MARK: - Filter

    func testNavigationSkipsTasksTheFilterHides() {
        let c = makeController("# Todo\n\n- [ ] A #x\n- [ ] B\n- [ ] C #x\n")
        c.viewStyle = .outline
        c.filter.tag = "x"
        c.selectedTaskID = task(c, "A #x").id
        c.selectAdjacent(direction: 1, keepEditing: false)
        XCTAssertEqual(c.selectedTaskID, task(c, "C #x").id)
    }

    func testMultiSelectionOnlySpansVisibleTasks() {
        let c = makeController("# Todo\n\n- [ ] A #x\n- [ ] B\n- [ ] C #x\n")
        c.filter.tag = "x"
        c.selectedTaskID = task(c, "A #x").id
        c.extendSelection(direction: 1)
        XCTAssertEqual(c.multiSelectedIDs, Set(["A #x", "C #x"].map { task(c, $0).id }))
    }

    func testClearingFilterRestoresNavigationOrder() {
        let c = makeController("# Todo\n\n- [ ] A #x\n- [ ] B\n")
        c.viewStyle = .outline
        c.filter.tag = "x"
        c.filter = TaskFilter()
        c.selectedTaskID = task(c, "A #x").id
        c.selectAdjacent(direction: 1, keepEditing: false)
        XCTAssertEqual(c.selectedTaskID, task(c, "B").id)
    }

    func testSettingDueKeepsPriorityAndTags() {
        let c = makeController("# Todo\n\n- [ ] Pay rent #home !!\n")
        let t = task(c, "Pay rent #home")
        c.rename(taskID: t.id, newText: TaskMetadata.settingDue(TaskDueDate(year: 2026, month: 12, day: 1), in: t.text))
        let updated = c.document.sections[0].tasks[0]
        XCTAssertEqual(updated.priority, .medium)
        XCTAssertEqual(updated.tags, ["home"])
        XCTAssertEqual(updated.dueDate, TaskDueDate(year: 2026, month: 12, day: 1))
        XCTAssertEqual(updated.displayTitle, "Pay rent")
    }

    // MARK: - Drag and drop

    func testDropReordersAndSelectionFollowsTheMovedTask() {
        let c = makeController(list)
        c.selectedTaskID = task(c, "A").id
        c.drop(taskID: task(c, "A").id, onto: task(c, "C").id, placement: .after)
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["B", "C", "A", "D"])
        XCTAssertEqual(c.selectedTaskID, task(c, "A").id)
    }

    func testDropNestingIsOneUndoStep() {
        let c = makeController(list)
        c.drop(taskID: task(c, "B").id, onto: task(c, "A").id, placement: .asSubtask)
        XCTAssertEqual(task(c, "A").subtasks.map(\.text), ["B"])
        c.undo()
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "B", "C", "D"])
    }

    func testRefusedDropIsSilent() {
        let c = makeController("# Todo\n\n- [ ] A\n  - [ ] a1\n- [ ] B\n")
        c.drop(taskID: task(c, "A").id, onto: task(c, "B").id, placement: .asSubtask)
        XCTAssertNil(c.errorMessage)
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "B"])
    }
}
