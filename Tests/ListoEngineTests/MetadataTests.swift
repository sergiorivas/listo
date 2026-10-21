import XCTest
@testable import ListoEngine

final class MetadataTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> TaskDueDate { TaskDueDate(year: y, month: m, day: d, calendar: cal)! }

    // MARK: - Due dates

    func testParsesDueDateToken() {
        XCTAssertEqual(TaskDueDate(token: "@2026-11-03", calendar: cal), day(2026, 11, 3))
        XCTAssertEqual(day(2026, 11, 3).token, "@2026-11-03")
    }

    func testRejectsMalformedAndImpossibleDates() {
        for bad in ["@2026-02-31", "@2026-13-01", "@26-11-03", "@2026-1-3", "2026-11-03", "@tomorrow", "@"] {
            XCTAssertNil(TaskDueDate(token: bad, calendar: cal), bad)
        }
    }

    func testDaysAndStatus() {
        let today = day(2026, 10, 21)
        XCTAssertEqual(day(2026, 10, 24).days(since: today, calendar: cal), 3)
        XCTAssertEqual(day(2026, 10, 20).days(since: today, calendar: cal), -1)
        XCTAssertEqual(DueStatus(due: day(2026, 10, 20), today: today, calendar: cal), .overdue)
        XCTAssertEqual(DueStatus(due: today, today: today, calendar: cal), .today)
        XCTAssertEqual(DueStatus(due: day(2026, 10, 28), today: today, calendar: cal), .soon)
        XCTAssertEqual(DueStatus(due: day(2026, 10, 29), today: today, calendar: cal), .later)
    }

    func testAddingDaysCrossesMonthBoundary() {
        XCTAssertEqual(day(2026, 10, 30).adding(days: 3, calendar: cal), day(2026, 11, 2))
    }

    // MARK: - Metadata in titles

    func testSplitsTitleDueAndTags() {
        let m = TaskMetadata("Pay rent @2026-11-03 #home #Money", calendar: cal)
        XCTAssertEqual(m.displayTitle, "Pay rent")
        XCTAssertEqual(m.due, day(2026, 11, 3))
        XCTAssertEqual(m.tags, ["home", "money"])
    }

    func testTokensCanSitMidTitle() {
        let m = TaskMetadata("Call #work mom", calendar: cal)
        XCTAssertEqual(m.displayTitle, "Call mom")
        XCTAssertEqual(m.tags, ["work"])
    }

    func testNonTagsStayInTheTitle() {
        let m = TaskMetadata("Fix #123 and C# and # alone #a/b", calendar: cal)
        XCTAssertEqual(m.displayTitle, "Fix #123 and C# and # alone #a/b")
        XCTAssertTrue(m.tags.isEmpty)
    }

    func testOnlyFirstDueDateCounts() {
        let m = TaskMetadata("A @2026-01-01 @2026-02-02", calendar: cal)
        XCTAssertEqual(m.due, day(2026, 1, 1))
        XCTAssertEqual(m.displayTitle, "A @2026-02-02")
    }

    func testDuplicateTagsCollapse() {
        XCTAssertEqual(TaskMetadata("x #a #A #a", calendar: cal).tags, ["a"])
    }

    func testTokenOnlyTitleIsNotBlank() {
        XCTAssertEqual(TaskMetadata("#inbox", calendar: cal).displayTitle, "#inbox")
    }

    func testSettingDueReplacesAndClears() {
        let set = TaskMetadata.settingDue(day(2026, 12, 1), in: "Pay rent @2026-11-03 #home", calendar: cal)
        XCTAssertEqual(set, "Pay rent #home @2026-12-01")
        XCTAssertEqual(TaskMetadata.settingDue(nil, in: set, calendar: cal), "Pay rent #home")
        XCTAssertEqual(TaskMetadata.settingDue(day(2026, 12, 1), in: "", calendar: cal), "@2026-12-01")
    }

    func testMetadataSurvivesPriorityMarkerAndRoundTrip() throws {
        let text = "# Todo\n\n- [ ] Pay rent @2026-11-03 #home !!\n"
        let doc = ListoParser.parse(text)
        let task = doc.sections[0].tasks[0]
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.dueDate, TaskDueDate(token: "@2026-11-03"))
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertEqual(task.displayTitle, "Pay rent")
        let editor = ListoEditor(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).md"), initialText: text, autoPersist: false)
        try editor.toggle(taskID: task.id)
        _ = try editor.undo()
        XCTAssertEqual(editor.currentText, text)
        try editor.renameTask(taskID: task.id, newText: "Pay rent @2026-12-01 #home")
        XCTAssertEqual(editor.currentText, "# Todo\n\n- [ ] Pay rent @2026-12-01 #home !!\n", "rename keeps the priority")
    }

    func testTagCountsOrderedByUseThenName() {
        let doc = ListoParser.parse("# T\n\n- [ ] a #b #a\n- [ ] c #b\n  - [ ] d #z\n")
        XCTAssertEqual(doc.tagCounts.map(\.tag), ["b", "a", "z"])
        XCTAssertEqual(doc.tagCounts.map(\.count), [2, 1, 1])
    }
}

final class TaskFilterTests: XCTestCase {
    private let today = TaskDueDate(year: 2026, month: 10, day: 21)!
    private let doc = ListoParser.parse("""
    # Todo

    - [ ] Pay rent @2026-10-20 #home !!!
    - [x] Café order #work
    - [ ] Write report @2026-10-25 #work
      - [ ] Draft intro
      - [x] Collect numbers
    - [ ] Call mom
      Remember the birthday

    """)
    private func titles(_ f: TaskFilter) -> [String] {
        f.visible(doc.sections[0].displayTasks, today: today).map(\.displayTitle)
    }

    func testInactiveFilterShowsEverything() {
        XCTAssertFalse(TaskFilter().isActive)
        XCTAssertEqual(titles(TaskFilter()).count, 4)
    }

    func testQueryIsCaseAndDiacriticInsensitiveAndAllWordsMustMatch() {
        var f = TaskFilter()
        f.query = "CAFE"
        XCTAssertEqual(titles(f), ["Café order"])
        f.query = "write rep"
        XCTAssertEqual(titles(f), ["Write report"])
        f.query = "write nothing"
        XCTAssertEqual(titles(f), [])
    }

    func testQuerySearchesNotes() {
        var f = TaskFilter()
        f.query = "birthday"
        XCTAssertEqual(titles(f), ["Call mom"])
    }

    func testStateAndPriorityAndTag() {
        var f = TaskFilter()
        f.state = .done
        XCTAssertTrue(titles(f).contains("Café order"))
        f = TaskFilter(); f.minPriority = .medium
        XCTAssertEqual(titles(f), ["Pay rent"])
        f = TaskFilter(); f.tag = "work"
        XCTAssertEqual(titles(f), ["Café order", "Write report"])
    }

    func testDueFilters() {
        var f = TaskFilter(); f.due = .overdue
        XCTAssertEqual(titles(f), ["Pay rent"])
        f.due = .thisWeek
        XCTAssertEqual(Set(titles(f)), ["Pay rent", "Write report"])
        f.due = .noDate
        // "Write report" has a date, but its undated subtasks match, which
        // keeps the parent on screen.
        XCTAssertEqual(Set(titles(f)), ["Café order", "Call mom", "Write report"])
        f.due = .hasDate
        XCTAssertEqual(Set(titles(f)), ["Pay rent", "Write report"])
    }

    func testMatchingSubtaskKeepsItsParentVisibleAndHidesSiblings() {
        var f = TaskFilter(); f.query = "intro"
        XCTAssertEqual(titles(f), ["Write report"])
        let parent = doc.sections[0].tasks[2]
        XCTAssertEqual(f.visibleSubtasks(of: parent, today: today).map(\.text), ["Draft intro"])
    }

    func testMatchingParentShowsAllItsSubtasks() {
        var f = TaskFilter(); f.query = "report"
        let parent = doc.sections[0].tasks[2]
        XCTAssertEqual(f.visibleSubtasks(of: parent, today: today).count, 2)
    }

    func testCountInSection() {
        var f = TaskFilter(); f.tag = "work"
        XCTAssertEqual(f.count(in: doc.sections[0], today: today), 2)
    }
}
