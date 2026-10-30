import XCTest
@testable import ListoEngine

/// Dates typed in words (`@tomorrow`, `@fri`, `@3d`) and how the editor
/// fixes them to a real `@YYYY-MM-DD` when a title is written.
final class TypedDateTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> TaskDueDate { TaskDueDate(year: y, month: m, day: d, calendar: cal)! }
    /// A Friday.
    private var friday: TaskDueDate { day(2026, 10, 30) }

    private func resolve(_ token: String) -> TaskDueDate? {
        TaskDueDate(relativeToken: token, today: friday, calendar: cal)
    }

    // MARK: - Tokens

    func testNamedDays() {
        XCTAssertEqual(resolve("@today"), friday)
        XCTAssertEqual(resolve("@hoy"), friday)
        XCTAssertEqual(resolve("@tomorrow"), day(2026, 10, 31))
        XCTAssertEqual(resolve("@Mañana"), day(2026, 10, 31), "case and accents are ignored")
        XCTAssertEqual(resolve("@manana"), day(2026, 10, 31))
    }

    func testWeekdayIsNextOneStrictlyAfterToday() {
        XCTAssertEqual(resolve("@mon"), day(2026, 11, 2))
        XCTAssertEqual(resolve("@lunes"), day(2026, 11, 2))
        XCTAssertEqual(resolve("@sat"), day(2026, 10, 31))
        XCTAssertEqual(resolve("@fri"), day(2026, 11, 6), "a Friday's @fri is next week's")
        XCTAssertEqual(resolve("@miércoles"), day(2026, 11, 4))
    }

    func testCountedDaysAndWeeks() {
        XCTAssertEqual(resolve("@3d"), day(2026, 11, 2))
        XCTAssertEqual(resolve("@2w"), day(2026, 11, 13))
        XCTAssertEqual(resolve("@1s"), day(2026, 11, 6), "Spanish semanas")
    }

    func testOtherWordsAreNotDates() {
        for word in ["@tom", "@sergio", "@0d", "@d", "@-2d", "@2026-11-03", "tomorrow", "@"] {
            XCTAssertNil(resolve(word), word)
        }
    }

    func testResolvingRewritesOnlyDateWordsAndKeepsSpacing() {
        let text = TaskMetadata.resolvingRelativeDates(in: "Call  @tom @tomorrow #work", today: friday, calendar: cal)
        XCTAssertEqual(text, "Call  @tom @2026-10-31 #work")
    }

    // MARK: - Editor

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeEditor(_ text: String) -> ListoEditor {
        let editor = ListoEditor(fileURL: tempDir.appendingPathComponent("list.md"), initialText: text)
        editor.today = { [friday] in friday }
        return editor
    }

    func testRenameResolvesTypedDateAndKeepsPriority() throws {
        let editor = makeEditor("# Todo\n- [ ] Pay rent !!\n")
        _ = try editor.renameTask(taskID: editor.document.sections[0].tasks[0].id, newText: "Pay rent @mon")
        XCTAssertEqual(editor.currentText, "# Todo\n- [ ] Pay rent @2026-11-02 !!\n")
    }

    func testAddTaskResolvesTypedDate() throws {
        let editor = makeEditor("# Todo\n")
        _ = try editor.addTask(text: "Renew domain @tomorrow", toSectionID: editor.document.sections[0].id)
        XCTAssertEqual(editor.document.sections[0].tasks[0].dueDate, day(2026, 10, 31))
    }
}
