import XCTest
@testable import ListoEngine

final class UndoTests: XCTestCase {
    var tempDir: URL!
    var fileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("backlog.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let text = "# a\n- [ ] Buy milk !!\n  a note\n  - [ ] Whole\n  - [ ] Oat\n- [ ] Pay rent\n\n# b\n- [ ] Call mom\n"

    func makeEditor() -> ListoEditor {
        ListoEditor(fileURL: fileURL, initialText: text, autoPersist: false)
    }

    private func task(_ editor: ListoEditor, _ title: String) -> ListoTask {
        editor.document.allTasksRecursive.first { $0.text == title }!
    }

    /// Runs `action`, then checks undo restores the exact original text and
    /// redo re-applies the exact result.
    private func assertRoundTrip(_ editor: ListoEditor, _ action: () throws -> LogEvent, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = editor.currentText
        let event = try action()
        let after = editor.currentText
        XCTAssertNotEqual(before, after, file: file, line: line)

        let undone = try XCTUnwrap(editor.undo(), file: file, line: line)
        XCTAssertEqual(editor.currentText, before, file: file, line: line)
        XCTAssertEqual(undone.event, .undone, file: file, line: line)
        XCTAssertEqual(undone.reverts, event.event, file: file, line: line)
        XCTAssertEqual(undone.taskID, event.taskID, file: file, line: line)
        XCTAssertEqual(undone.text, event.text, file: file, line: line)

        let redone = try XCTUnwrap(editor.redo(), file: file, line: line)
        XCTAssertEqual(editor.currentText, after, file: file, line: line)
        XCTAssertEqual(redone.event, .redone, file: file, line: line)
        XCTAssertEqual(redone.reverts, event.event, file: file, line: line)
        try XCTUnwrap(editor.undo(), file: file, line: line)
    }

    func testUndoDeleteTaskRestoresNoteAndSubtasks() throws {
        let editor = makeEditor()
        try assertRoundTrip(editor) { try editor.deleteTask(taskID: self.task(editor, "Buy milk").id) }
    }

    func testUndoDeleteSubtask() throws {
        let editor = makeEditor()
        try assertRoundTrip(editor) { try editor.deleteTask(taskID: self.task(editor, "Whole").id) }
    }

    func testUndoMove() throws {
        let editor = makeEditor()
        let target = editor.document.sections[1].id
        try assertRoundTrip(editor) { try editor.moveTask(taskID: self.task(editor, "Pay rent").id, toSectionID: target) }
    }

    func testUndoMoveToAdjacentSectionRecordsOneStep() throws {
        let editor = makeEditor()
        let before = editor.currentText
        try editor.moveTaskToAdjacentSection(taskID: task(editor, "Pay rent").id, direction: 1)
        try editor.undo()
        XCTAssertEqual(editor.currentText, before)
        XCTAssertFalse(editor.canUndo)
    }

    func testUndoPriorityChange() throws {
        let editor = makeEditor()
        try assertRoundTrip(editor) { try editor.setPriority(taskID: self.task(editor, "Pay rent").id, priority: .high) }
        try assertRoundTrip(editor) { try editor.setPriority(taskID: self.task(editor, "Buy milk").id, priority: .none) }
    }

    func testUndoCheckTaskAlsoRestoresDroppedPriority() throws {
        let editor = makeEditor()
        // Completing drops the `!!` marker; undo must bring it back.
        try assertRoundTrip(editor) { try editor.toggle(taskID: self.task(editor, "Buy milk").id) }
        XCTAssertEqual(task(editor, "Buy milk").priority, .medium)
    }

    func testUndoCheckSubtask() throws {
        let editor = makeEditor()
        try assertRoundTrip(editor) { try editor.toggle(taskID: self.task(editor, "Oat").id) }
    }

    func testUndoStepsBackThroughSeveralActionsThenRedoForward() throws {
        let editor = makeEditor()
        let start = editor.currentText
        try editor.toggle(taskID: task(editor, "Pay rent").id)
        let afterToggle = editor.currentText
        try editor.deleteTask(taskID: task(editor, "Call mom").id)
        let afterDelete = editor.currentText

        try editor.undo()
        XCTAssertEqual(editor.currentText, afterToggle)
        try editor.undo()
        XCTAssertEqual(editor.currentText, start)
        XCTAssertNil(try editor.undo())

        try editor.redo()
        try editor.redo()
        XCTAssertEqual(editor.currentText, afterDelete)
        XCTAssertNil(try editor.redo())
    }

    func testNewActionClearsRedo() throws {
        let editor = makeEditor()
        try editor.toggle(taskID: task(editor, "Pay rent").id)
        try editor.undo()
        XCTAssertTrue(editor.canRedo)
        try editor.toggle(taskID: task(editor, "Call mom").id)
        XCTAssertFalse(editor.canRedo)
    }

    func testExternalChangeDropsHistoryButUnchangedReloadKeepsIt() throws {
        let editor = makeEditor()
        try editor.toggle(taskID: task(editor, "Pay rent").id)
        editor.loadExternalText(editor.currentText)
        XCTAssertTrue(editor.canUndo)
        editor.loadExternalText(editor.currentText + "- [ ] Typed in free mode\n")
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
    }

    func testHistoryIsBounded() throws {
        let editor = makeEditor()
        let id = task(editor, "Pay rent").id
        for _ in 0..<(ListoEditor.maxUndoDepth + 20) { try editor.toggle(taskID: id) }
        var steps = 0
        while try editor.undo() != nil { steps += 1 }
        XCTAssertEqual(steps, ListoEditor.maxUndoDepth)
    }

    func testUndoRedoAreLoggedAndFormatted() throws {
        let editor = makeEditor()
        try editor.deleteTask(taskID: task(editor, "Pay rent").id)
        try editor.undo()
        try editor.redo()
        let log = try editor.readLog()
        XCTAssertEqual(log.map(\.event), [.deleted, .undone, .redone])
        XCTAssertEqual(LogFormatter.describe(log[1]), "undone — deleted: \"Pay rent\"")
        XCTAssertEqual(LogFormatter.describe(log[2]), "redone — deleted: \"Pay rent\"")
    }

    func testRevertsFieldRoundTripsAndOldLinesStillDecode() throws {
        let event = LogEvent(ts: Date(timeIntervalSince1970: 1_700_000_000), file: "x.md", event: .undone, taskID: "t_1", sectionPath: .path(["a"]),
                             text: "T", source: .app, interpretedBy: .userAction, reverts: .completed)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(LogEvent.self, from: data), event)

        let legacy = try JSONEncoder().encode(LogEvent(file: "x.md", event: .deleted, taskID: "t_1", sectionPath: nil,
                                                       text: "T", source: .app, interpretedBy: .userAction))
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("reverts"))
        XCTAssertNil(try JSONDecoder().decode(LogEvent.self, from: legacy).reverts)
    }
}
