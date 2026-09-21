import XCTest
@testable import ListoEngine

final class PriorityTests: XCTestCase {
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

    // MARK: - Parsing

    func testTrailingMarkersAreParsedOffTheTitle() {
        let doc = ListoParser.parse("# a\n- [ ] Low !\n- [ ] Mid !!\n- [x] High !!!\n- [ ] None\n")
        let tasks = doc.sections[0].tasks
        XCTAssertEqual(tasks.map(\.text), ["Low", "Mid", "High", "None"])
        XCTAssertEqual(tasks.map(\.priority), [.low, .medium, .high, .none])
    }

    func testOnlyASeparateTrailingTokenIsAMarker() {
        let doc = ListoParser.parse("# a\n- [ ] Call mom!\n- [ ] Wow !!!!\n- [ ] Hey !! there\n- [ ] Edgy!!\n")
        let tasks = doc.sections[0].tasks
        XCTAssertEqual(tasks.map(\.text), ["Call mom!", "Wow !!!!", "Hey !! there", "Edgy!!"])
        XCTAssertTrue(tasks.allSatisfy { $0.priority == .none })
    }

    func testTrailingWhitespaceAfterMarkerIsIgnored() {
        let doc = ListoParser.parse("# a\n- [ ] Buy milk !!  \n")
        XCTAssertEqual(doc.sections[0].tasks[0].text, "Buy milk")
        XCTAssertEqual(doc.sections[0].tasks[0].priority, .medium)
    }

    func testSubtasksCanHaveAPriorityAndNoteStaysSeparate() {
        let doc = ListoParser.parse("# a\n- [ ] Parent !\n  a note!!!\n  - [ ] Child !!!\n")
        let parent = doc.sections[0].tasks[0]
        XCTAssertEqual(parent.priority, .low)
        XCTAssertEqual(parent.note, "a note!!!")
        XCTAssertEqual(parent.subtasks[0].text, "Child")
        XCTAssertEqual(parent.subtasks[0].priority, .high)
    }

    func testPriorityDoesNotChangeTheTaskID() {
        let a = ListoParser.parse("# a\n- [ ] Buy milk\n").sections[0].tasks[0].id
        let b = ListoParser.parse("# a\n- [ ] Buy milk !!!\n").sections[0].tasks[0].id
        XCTAssertEqual(a, b)
    }

    func testSerializerRoundTripsMarkers() {
        let text = "# a\n- [ ] Low !\n  - [x] Sub !!!\n- [ ] Plain"
        XCTAssertEqual(ListoSerializer.serialize(ListoParser.parse(text)), text)
    }

    // MARK: - Sorting

    func testDisplayOrderIsByPriorityAndStableWithinAPriority() {
        let doc = ListoParser.parse("# a\n- [ ] n1\n- [ ] m1 !!\n- [ ] h1 !!!\n- [ ] n2\n- [ ] h2 !!!\n- [ ] l1 !\n- [ ] m2 !!\n")
        XCTAssertEqual(doc.sections[0].displayTasks.map(\.text), ["h1", "h2", "m1", "m2", "l1", "n1", "n2"])
        // The file order is untouched.
        XCTAssertEqual(doc.sections[0].tasks.map(\.text), ["n1", "m1", "h1", "n2", "h2", "l1", "m2"])
    }

    func testSubtasksAreSortedToo() {
        let doc = ListoParser.parse("# a\n- [ ] P\n  - [ ] s1\n  - [ ] s2 !!!\n")
        XCTAssertEqual(doc.sections[0].tasks[0].displaySubtasks.map(\.text), ["s2", "s1"])
        XCTAssertEqual(doc.allTasksInDisplayOrder.map(\.text), ["P", "s2", "s1"])
    }

    // MARK: - Editor

    func testSetPriorityWritesAndClearsTheMarker() throws {
        let editor = makeEditor("# a\n- [ ] Task A\n- [ ] Task B\n")
        let id = editor.document.sections[0].tasks[0].id

        let set = try editor.setPriority(taskID: id, priority: .high)
        XCTAssertEqual(set.event, .priorityChanged)
        XCTAssertEqual(set.text, "Task A !!!")
        XCTAssertEqual(editor.currentText, "# a\n- [ ] Task A !!!\n- [ ] Task B\n")
        XCTAssertEqual(editor.document.sections[0].tasks[0].priority, .high)
        XCTAssertEqual(editor.document.sections[0].tasks[0].id, id, "priority must not change identity")

        let cleared = try editor.setPriority(taskID: id, priority: .none)
        XCTAssertEqual(cleared.text, "Task A")
        XCTAssertEqual(editor.currentText, "# a\n- [ ] Task A\n- [ ] Task B\n")
    }

    func testSetPriorityOnSubtaskKeepsIndentAndNote() throws {
        let editor = makeEditor("# a\n- [ ] P\n  a note\n  - [ ] S\n")
        let sub = editor.document.sections[0].tasks[0].subtasks[0]
        let event = try editor.setPriority(taskID: sub.id, priority: .medium)
        XCTAssertEqual(event.text, "P > S !!")
        XCTAssertEqual(editor.currentText, "# a\n- [ ] P\n  a note\n  - [ ] S !!\n")
    }

    func testToggleKeepsThePriorityMarker() throws {
        let editor = makeEditor("# a\n- [ ] Task A  !!\n")
        try editor.toggle(taskID: editor.document.sections[0].tasks[0].id)
        XCTAssertEqual(editor.currentText, "# a\n- [x] Task A  !!\n")
        XCTAssertEqual(editor.document.sections[0].tasks[0].priority, .medium)
    }

    func testRenameKeepsPriorityUnlessANewMarkerIsTyped() throws {
        let editor = makeEditor("# a\n- [ ] Old !!!\n")
        let event = try editor.renameTask(taskID: editor.document.sections[0].tasks[0].id, newText: "New")
        XCTAssertEqual(event.text, "New")
        XCTAssertEqual(editor.currentText, "# a\n- [ ] New !!!\n")

        try editor.renameTask(taskID: editor.document.sections[0].tasks[0].id, newText: "New !")
        XCTAssertEqual(editor.currentText, "# a\n- [ ] New !\n")
        XCTAssertEqual(editor.document.sections[0].tasks[0].text, "New")
    }

    func testReorderOnlyMovesWithinTheSamePriority() throws {
        // Display order: H1, H2, N1, N2 — file order is interleaved.
        let editor = makeEditor("# a\n- [ ] N1\n- [ ] H1 !!!\n- [ ] N2\n- [ ] H2 !!!\n")
        func display() -> [String] { editor.document.sections[0].displayTasks.map(\.text) }
        XCTAssertEqual(display(), ["H1", "H2", "N1", "N2"])

        let h2 = editor.document.sections[0].displayTasks[1]
        try editor.reorderTask(taskID: h2.id, direction: -1)
        XCTAssertEqual(display(), ["H2", "H1", "N1", "N2"])

        // Can't cross into another priority: N1 up would swap with H1.
        let n1 = editor.document.sections[0].displayTasks[2]
        XCTAssertThrowsError(try editor.reorderTask(taskID: n1.id, direction: -1)) {
            XCTAssertEqual($0 as? ListoEditorError, .noSiblingInDirection)
        }
        // ...and the last of a group can't move down into the next group.
        let h1 = editor.document.sections[0].displayTasks[1]
        XCTAssertThrowsError(try editor.reorderTask(taskID: h1.id, direction: 1))

        // Non-adjacent-in-the-file neighbours still swap cleanly.
        let n2 = editor.document.sections[0].displayTasks[3]
        try editor.reorderTask(taskID: n2.id, direction: -1)
        XCTAssertEqual(display(), ["H2", "H1", "N2", "N1"])
    }

    func testIndentNestsUnderTheTaskAboveOnScreen() throws {
        // File: N, H — on screen H is first, so indenting N goes under H.
        let editor = makeEditor("# a\n- [ ] N\n- [ ] H !!!\n")
        let n = editor.document.sections[0].displayTasks[1]
        try editor.indentTask(taskID: n.id)
        let tasks = editor.document.sections[0].tasks
        XCTAssertEqual(tasks.map(\.text), ["H"])
        XCTAssertEqual(tasks[0].subtasks.map(\.text), ["N"])
    }

    func testInsertAfterAHighPriorityTaskLandsRightBelowIt() throws {
        let editor = makeEditor("# a\n- [ ] Other\n- [ ] H !!!\n")
        let h = editor.document.sections[0].displayTasks[0]
        try editor.insertTaskAfter(taskID: h.id, text: "New")
        XCTAssertEqual(editor.document.sections[0].displayTasks.map(\.text), ["H", "Other", "New"])
    }

    // MARK: - Differ / log

    func testFreeModePriorityChangeIsLogged() {
        let old = "# a\n- [ ] Task A\n"
        let new = "# a\n- [ ] Task A !!\n"
        guard case .resolved(let events) = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new) else {
            return XCTFail("expected resolved")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, .priorityChanged)
        XCTAssertEqual(events[0].text, "Task A !!")
        XCTAssertEqual(LogFormatter.describe(events[0]), "priority set to !!: \"Task A\"")
    }

    func testFreeModePriorityRemovalIsLogged() {
        guard case .resolved(let events) = ListoDiffer.diff(
            fileName: "f.md", oldText: "# a\n- [ ] Task A !\n", newText: "# a\n- [ ] Task A\n"
        ) else { return XCTFail("expected resolved") }
        XCTAssertEqual(events.map(\.event), [.priorityChanged])
        XCTAssertEqual(LogFormatter.describe(events[0]), "priority cleared: \"Task A\"")
    }

    func testSubtaskPriorityLogFormat() {
        guard case .resolved(let events) = ListoDiffer.diff(
            fileName: "f.md", oldText: "# a\n- [ ] P\n  - [ ] S\n", newText: "# a\n- [ ] P\n  - [ ] S !!!\n"
        ) else { return XCTFail("expected resolved") }
        XCTAssertEqual(events[0].text, "P > S !!!")
        XCTAssertEqual(LogFormatter.describe(events[0]), "priority set to !!!: \"P > S\"")
    }
}
