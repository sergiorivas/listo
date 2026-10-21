import XCTest
@testable import ListoEngine

final class DropTests: XCTestCase {
    private func makeEditor(_ text: String) -> ListoEditor {
        ListoEditor(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).md"), initialText: text, autoPersist: false)
    }
    private func id(_ editor: ListoEditor, _ text: String) -> UUID {
        editor.document.allTasksRecursive.first { $0.text == text }!.id
    }
    private func titles(_ editor: ListoEditor, section: Int = 0) -> [String] {
        editor.document.sections[section].tasks.map(\.text)
    }

    private let list = "# One\n\n- [ ] A\n- [ ] B\n- [ ] C\n\n# Two\n\n- [ ] X\n"

    // MARK: - Before / after

    func testDropBelowTargetMovesDownwards() throws {
        let e = makeEditor(list)
        try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "B"), placement: .after)
        XCTAssertEqual(titles(e), ["B", "A", "C"])
    }

    func testDropAboveTargetMovesUpwards() throws {
        let e = makeEditor(list)
        try e.moveTask(taskID: id(e, "C"), relativeTo: id(e, "A"), placement: .before)
        XCTAssertEqual(titles(e), ["C", "A", "B"])
    }

    func testDropAtTheVeryEnd() throws {
        let e = makeEditor(list)
        try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "C"), placement: .after)
        XCTAssertEqual(titles(e), ["B", "C", "A"])
    }

    func testBlockTravelsWithNoteAndSubtasks() throws {
        let e = makeEditor("# T\n\n- [ ] A\n  a note\n  - [ ] a1\n- [ ] B\n")
        try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "B"), placement: .after)
        XCTAssertEqual(e.currentText, "# T\n\n- [ ] B\n- [ ] A\n  a note\n  - [ ] a1\n")
    }

    func testDropOnTaskInAnotherSectionMovesAcross() throws {
        let e = makeEditor(list)
        try e.moveTask(taskID: id(e, "B"), relativeTo: id(e, "X"), placement: .before)
        XCTAssertEqual(titles(e, section: 0), ["A", "C"])
        XCTAssertEqual(titles(e, section: 1), ["B", "X"])
    }

    func testReorderLogsReorderedAndCrossSectionLogsMovedSection() throws {
        let e = makeEditor(list)
        XCTAssertEqual(try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "C"), placement: .after).event, .reordered)
        XCTAssertEqual(try e.moveTask(taskID: id(e, "B"), relativeTo: id(e, "X"), placement: .after).event, .movedSection)
    }

    // MARK: - Subtasks

    func testSubtasksReorderWithinTheirParent() throws {
        let e = makeEditor("# T\n\n- [ ] P\n  - [ ] s1\n  - [ ] s2\n  - [ ] s3\n")
        try e.moveTask(taskID: id(e, "s3"), relativeTo: id(e, "s1"), placement: .before)
        XCTAssertEqual(e.document.sections[0].tasks[0].subtasks.map(\.text), ["s3", "s1", "s2"])
    }

    func testSubtaskDroppedBesideSubtaskOfAnotherParentChangesParent() throws {
        let e = makeEditor("# T\n\n- [ ] P\n  - [ ] s1\n- [ ] Q\n  - [ ] t1\n")
        let event = try e.moveTask(taskID: id(e, "s1"), relativeTo: id(e, "t1"), placement: .after)
        let tasks = e.document.sections[0].tasks
        XCTAssertTrue(tasks[0].subtasks.isEmpty)
        XCTAssertEqual(tasks[1].subtasks.map(\.text), ["t1", "s1"])
        XCTAssertEqual(event.event, .reindented)
        XCTAssertEqual(event.text, "Q > s1")
    }

    func testTopLevelTaskCannotBeDroppedBetweenSubtasks() {
        let e = makeEditor("# T\n\n- [ ] P\n  - [ ] s1\n- [ ] Q\n")
        XCTAssertThrowsError(try e.moveTask(taskID: id(e, "Q"), relativeTo: id(e, "s1"), placement: .before)) {
            XCTAssertEqual($0 as? ListoEditorError, .invalidMove)
        }
    }

    // MARK: - Nesting

    func testDropOntoTaskNestsAsLastSubtask() throws {
        let e = makeEditor("# T\n\n- [ ] A\n  - [ ] a1\n- [ ] B\n- [ ] C\n")
        let event = try e.moveTask(taskID: id(e, "C"), relativeTo: id(e, "A"), placement: .asSubtask)
        XCTAssertEqual(e.currentText, "# T\n\n- [ ] A\n  - [ ] a1\n  - [ ] C\n- [ ] B\n")
        XCTAssertEqual(event.event, .reindented)
        XCTAssertEqual(event.text, "A > C")
    }

    func testNestingKeepsStateAndPriority() throws {
        let e = makeEditor("# T\n\n- [ ] A\n- [x] B !!\n")
        try e.moveTask(taskID: id(e, "B"), relativeTo: id(e, "A"), placement: .asSubtask)
        XCTAssertEqual(e.currentText, "# T\n\n- [ ] A\n  - [x] B !!\n")
    }

    func testNestingTaskWithSubtasksOrNoteIsRefused() {
        let e = makeEditor("# T\n\n- [ ] A\n- [ ] B\n  - [ ] b1\n- [ ] C\n  a note\n")
        for name in ["B", "C"] {
            XCTAssertThrowsError(try e.moveTask(taskID: id(e, name), relativeTo: id(e, "A"), placement: .asSubtask)) {
                XCTAssertEqual($0 as? ListoEditorError, .taskHasContent)
            }
        }
    }

    func testSubtaskCanMoveUnderAnotherTask() throws {
        let e = makeEditor("# T\n\n- [ ] P\n  - [ ] s1\n- [ ] Q\n")
        try e.moveTask(taskID: id(e, "s1"), relativeTo: id(e, "Q"), placement: .asSubtask)
        XCTAssertEqual(e.currentText, "# T\n\n- [ ] P\n- [ ] Q\n  - [ ] s1\n")
    }

    // MARK: - Invalid

    func testDropOntoItselfOrOwnSubtaskIsInvalid() {
        let e = makeEditor("# T\n\n- [ ] A\n  - [ ] a1\n")
        XCTAssertThrowsError(try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "A"), placement: .after))
        XCTAssertThrowsError(try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "a1"), placement: .after))
    }

    func testDropIsOneUndoStep() throws {
        let e = makeEditor(list)
        try e.moveTask(taskID: id(e, "A"), relativeTo: id(e, "C"), placement: .after)
        _ = try e.undo()
        XCTAssertEqual(e.currentText, list)
    }
}
