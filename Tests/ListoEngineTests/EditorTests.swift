import XCTest
@testable import ListoEngine

final class EditorTests: XCTestCase {
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

    func makeEditor(_ text: String) -> ListoEditor {
        ListoEditor(fileURL: fileURL, initialText: text)
    }

    func testAddTaskWritesMinimalLine() throws {
        let editor = makeEditor("# ahora\n- [ ] Existing\n\n# mas tarde\n")
        let section = editor.document.sections[0]
        let event = try editor.addTask(text: "New one", toSectionID: section.id)
        XCTAssertEqual(event.event, .created)
        XCTAssertEqual(event.text, "New one")
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["Existing", "New one"])
        XCTAssertTrue(editor.currentText.contains("- [ ] New one"))
    }

    func testToggleCompletesAndReopens() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n")
        let taskID = editor.document.sections[0].tasks[0].id
        let completed = try editor.toggle(taskID: taskID)
        XCTAssertEqual(completed.event, .completed)
        XCTAssertEqual(editor.document.sections[0].tasks[0].state, .done)

        let newID = editor.document.sections[0].tasks[0].id
        let reopened = try editor.toggle(taskID: newID)
        XCTAssertEqual(reopened.event, .reopened)
        XCTAssertEqual(editor.document.sections[0].tasks[0].state, .open)
    }

    func testRenameTask() throws {
        let editor = makeEditor("# ahora\n- [ ] Old text\n")
        let taskID = editor.document.sections[0].tasks[0].id
        let event = try editor.renameTask(taskID: taskID, newText: "New text")
        XCTAssertEqual(event.event, .edited)
        XCTAssertEqual(editor.document.sections[0].tasks[0].text, "New text")
    }

    func testSetNoteAddsIndentedLines() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n- [ ] Task B\n")
        let taskID = editor.document.sections[0].tasks[0].id
        _ = try editor.setNote(taskID: taskID, note: "line one\nline two")
        let task = editor.document.sections[0].tasks[0]
        XCTAssertEqual(task.note, "  line one\n  line two")
        // Task B must not have shifted into the note.
        XCTAssertEqual(editor.document.sections[0].tasks[1].text, "Task B")
    }

    func testIndentMakesSubtaskOfPrecedingSibling() throws {
        let editor = makeEditor("# ahora\n- [ ] First\n- [ ] Second\n")
        let secondID = editor.document.sections[0].tasks[1].id
        let event = try editor.indentTask(taskID: secondID)
        XCTAssertEqual(event.event, .reindented)
        XCTAssertEqual(editor.document.sections[0].tasks.count, 1)
        XCTAssertEqual(editor.document.sections[0].tasks[0].subtasks.first?.text, "Second")
    }

    func testIndentFirstTaskThrows() {
        let editor = makeEditor("# ahora\n- [ ] Only\n")
        let id = editor.document.sections[0].tasks[0].id
        XCTAssertThrowsError(try editor.indentTask(taskID: id))
    }

    func testMoveTaskBetweenSections() throws {
        let editor = makeEditor("# ahora\n- [ ] Migrate DB\n\n# mas tarde\n- [ ] Other\n")
        let taskID = editor.document.sections[0].tasks[0].id
        let targetID = editor.document.sections[1].id
        let event = try editor.moveTask(taskID: taskID, toSectionID: targetID)
        XCTAssertEqual(event.event, .movedSection)
        XCTAssertEqual(editor.document.sections[0].tasks.count, 0)
        XCTAssertEqual(editor.document.sections[1].tasks.map(\.text), ["Other", "Migrate DB"])
    }

    func testMoveTaskWithNoteCarriesNoteAlong() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n  a note line\n\n# mas tarde\n")
        let taskID = editor.document.sections[0].tasks[0].id
        let targetID = editor.document.sections[1].id
        _ = try editor.moveTask(taskID: taskID, toSectionID: targetID)
        let moved = editor.document.sections[1].tasks[0]
        XCTAssertEqual(moved.text, "Task A")
        XCTAssertNotNil(moved.note)
    }

    func testDeleteTask() throws {
        let editor = makeEditor("# ahora\n- [ ] Keep\n- [ ] Remove\n")
        let taskID = editor.document.sections[0].tasks[1].id
        let event = try editor.deleteTask(taskID: taskID)
        XCTAssertEqual(event.event, .deleted)
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["Keep"])
    }

    func testEachActionAppendsToLogFile() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n")
        let taskID = editor.document.sections[0].tasks[0].id
        _ = try editor.toggle(taskID: taskID)
        let events = try editor.readLog()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, .app)
        XCTAssertEqual(events[0].interpretedBy, .userAction)
    }

    func testFileOnDiskMatchesInMemoryDocument() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n")
        let taskID = editor.document.sections[0].tasks[0].id
        _ = try editor.toggle(taskID: taskID)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(onDisk, editor.currentText)
        XCTAssertTrue(onDisk.contains("- [x] Task A"))
    }
}
