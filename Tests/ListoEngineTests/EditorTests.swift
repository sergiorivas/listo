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

    func testRenameSection() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n\n# mas tarde\n")
        let sectionID = editor.document.sections[0].id
        let event = try editor.renameSection(sectionID: sectionID, newTitle: "hoy")
        XCTAssertEqual(event.event, .edited)
        XCTAssertEqual(editor.document.sections[0].title, "hoy")
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["Task A"])
        XCTAssertTrue(editor.currentText.contains("# hoy"))
    }

    func testRenameSubsectionPreservesLevel() throws {
        let editor = makeEditor("# backlog\n## prioridad 2\n- [ ] Task A\n")
        let sub = editor.document.sections[0].subsections[0]
        _ = try editor.renameSection(sectionID: sub.id, newTitle: "prioridad 1")
        let renamed = editor.document.sections[0].subsections[0]
        XCTAssertEqual(renamed.title, "prioridad 1")
        XCTAssertEqual(renamed.level, 2)
        XCTAssertTrue(editor.currentText.contains("## prioridad 1"))
    }

    func testSetNoteAddsIndentedLines() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n- [ ] Task B\n")
        let taskID = editor.document.sections[0].tasks[0].id
        _ = try editor.setNote(taskID: taskID, note: "line one\nline two")
        let task = editor.document.sections[0].tasks[0]
        // The file gets the indented lines, but the in-memory note is
        // stored dedented (see ListoParser.finalizeNote) so re-editing it
        // doesn't feed already-indented text back into setNote.
        XCTAssertEqual(task.note, "line one\nline two")
        XCTAssertTrue(editor.currentText.contains("  line one\n  line two"))
        // Task B must not have shifted into the note.
        XCTAssertEqual(editor.document.sections[0].tasks[1].text, "Task B")
    }

    /// The bug this guards against: re-saving a note with unchanged content
    /// must not add another indent level each time.
    func testResavingNoteDoesNotCompoundIndentation() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n")
        let taskID = editor.document.sections[0].tasks[0].id
        _ = try editor.setNote(taskID: taskID, note: "hello")

        // Simulate reopening the note editor: it's seeded from task.note,
        // exactly as the popover does, then saved back unchanged.
        for _ in 0..<3 {
            let currentNote = editor.document.sections[0].tasks[0].note
            _ = try editor.setNote(taskID: taskID, note: currentNote)
        }

        let task = editor.document.sections[0].tasks[0]
        XCTAssertEqual(task.note, "hello")
        XCTAssertTrue(editor.currentText.contains("  hello"))
        XCTAssertFalse(editor.currentText.contains("    hello"))
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

    /// A, B as top-level siblings. Indenting B makes it a subtask of A
    /// (depth 1); Listo's tree is only two levels deep, so indenting it
    /// again must refuse rather than nest a subtask under a subtask.
    func testIndentUpToMaxDepthThenRefuses() throws {
        let editor = makeEditor("# ahora\n- [ ] A\n- [ ] B\n")
        let bID = editor.document.sections[0].tasks[1].id

        try editor.indentTask(taskID: bID)

        XCTAssertEqual(editor.document.sections[0].tasks.count, 1)
        let a = editor.document.sections[0].tasks[0]
        let b = a.subtasks[0]
        XCTAssertEqual(b.text, "B")
        XCTAssertEqual(editor.document.depth(of: b), 1)

        XCTAssertThrowsError(try editor.indentTask(taskID: b.id)) { error in
            XCTAssertEqual(error as? ListoEditorError, .maxDepthReached)
        }
    }

    func testOutdentReversesIndent() throws {
        let editor = makeEditor("# ahora\n- [ ] First\n- [ ] Second\n")
        let secondID = editor.document.sections[0].tasks[1].id
        try editor.indentTask(taskID: secondID)
        XCTAssertEqual(editor.document.sections[0].tasks.count, 1)

        let nestedID = editor.document.sections[0].tasks[0].subtasks[0].id
        let event = try editor.outdentTask(taskID: nestedID)
        XCTAssertEqual(event.event, .reindented)
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["First", "Second"])
        XCTAssertEqual(editor.document.sections[0].tasks[0].subtasks.count, 0)
    }

    func testInsertTaskAfterAddsTopLevelSibling() throws {
        let editor = makeEditor("# ahora\n- [ ] First\n- [ ] Third\n")
        let firstID = editor.document.sections[0].tasks[0].id
        let event = try editor.insertTaskAfter(taskID: firstID, text: "Second")
        XCTAssertEqual(event.event, .created)
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(editor.document.depth(of: editor.document.sections[0].tasks[1]), 0)
    }

    func testInsertTaskAfterAddsSubtaskSibling() throws {
        let editor = makeEditor("# ahora\n- [ ] Parent\n  - [ ] Sub A\n  - [ ] Sub C\n")
        let subAID = editor.document.sections[0].tasks[0].subtasks[0].id
        let event = try editor.insertTaskAfter(taskID: subAID, text: "Sub B")
        XCTAssertEqual(event.event, .created)
        let parent = editor.document.sections[0].tasks[0]
        XCTAssertEqual(parent.subtasks.map(\.text), ["Sub A", "Sub B", "Sub C"])
        XCTAssertEqual(editor.document.depth(of: parent.subtasks[1]), 1)
    }

    /// Pressing Return on a task that already has subtasks must add the new
    /// sibling below all of them, not split them apart.
    func testInsertTaskAfterParentWithSubtasksLandsAfterThem() throws {
        let editor = makeEditor("# ahora\n- [ ] Parent\n  - [ ] Sub A\n- [ ] Other\n")
        let parentID = editor.document.sections[0].tasks[0].id
        try editor.insertTaskAfter(taskID: parentID, text: "New sibling")
        XCTAssertEqual(editor.document.sections[0].tasks.map(\.text), ["Parent", "New sibling", "Other"])
        XCTAssertEqual(editor.document.sections[0].tasks[0].subtasks.map(\.text), ["Sub A"])
    }

    func testInsertTaskAfterTracksLastActionTaskID() throws {
        let editor = makeEditor("# ahora\n- [ ] First\n")
        let firstID = editor.document.sections[0].tasks[0].id
        try editor.insertTaskAfter(taskID: firstID, text: "Second")
        let newID = editor.document.sections[0].tasks[1].id
        XCTAssertEqual(editor.lastActionTaskID, newID)
    }

    func testOutdentTopLevelTaskThrows() {
        let editor = makeEditor("# ahora\n- [ ] Only\n")
        let id = editor.document.sections[0].tasks[0].id
        XCTAssertThrowsError(try editor.outdentTask(taskID: id)) { error in
            XCTAssertEqual(error as? ListoEditorError, .alreadyTopLevel)
        }
    }

    /// Notes are a top-level-task-only feature — Listo's tree is
    /// deliberately just task + subtask, and only the task carries a note.
    func testSetNoteOnSubtaskThrows() throws {
        let editor = makeEditor("# ahora\n- [ ] A\n  - [ ] B\n")
        let b = editor.document.sections[0].tasks[0].subtasks[0]
        XCTAssertThrowsError(try editor.setNote(taskID: b.id, note: "nope")) { error in
            XCTAssertEqual(error as? ListoEditorError, .subtaskNoteNotSupported)
        }
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

    func testDeleteSectionRemovesItsTasksAndSubsections() throws {
        let editor = makeEditor("# ahora\n- [ ] Task A\n\n# backlog\n## prioridad 2\n- [ ] Task B\n\n# mas tarde\n- [ ] Task C\n")
        let backlogID = editor.document.sections[1].id
        let event = try editor.deleteSection(sectionID: backlogID)
        XCTAssertEqual(event.event, .deleted)
        XCTAssertEqual(editor.document.sections.map(\.title), ["ahora", "mas tarde"])
        XCTAssertFalse(editor.currentText.contains("Task B"))
        XCTAssertTrue(editor.currentText.contains("Task A"))
        XCTAssertTrue(editor.currentText.contains("Task C"))
    }

    func testDeleteSubtask() throws {
        let editor = makeEditor("# ahora\n- [ ] Parent\n  - [ ] Child\n")
        let childID = editor.document.sections[0].tasks[0].subtasks[0].id
        let event = try editor.deleteTask(taskID: childID)
        XCTAssertEqual(event.event, .deleted)
        XCTAssertEqual(editor.document.sections[0].tasks[0].subtasks.count, 0)
        XCTAssertTrue(editor.document.sections[0].tasks.contains { $0.text == "Parent" })
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
