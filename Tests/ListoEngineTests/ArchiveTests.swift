import XCTest
@testable import ListoEngine

final class ArchiveTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!
    private var archiveURL: URL { ListoEditor.archiveURL(for: fileURL) }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("Launch.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeEditor(_ text: String) -> ListoEditor {
        let editor = ListoEditor(fileURL: fileURL, initialText: text)
        editor.today = { TaskDueDate(year: 2026, month: 10, day: 30)! }
        return editor
    }

    private let list = """
    # To Do

    - [ ] Open
    - [x] Shipped
      Release notes are in the wiki
      - [ ] Leftover subtask

    ## Later

    - [x] Old idea

    # Done

    - [x] Dark mode
    - [ ] Reopened
      - [x] Done subtask stays with its parent

    """

    func testArchiveURLSitsNextToTheList() {
        XCTAssertEqual(archiveURL.lastPathComponent, "Launch.archive.md")
        XCTAssertEqual(archiveURL.deletingLastPathComponent(), fileURL.deletingLastPathComponent())
    }

    func testMovesFinishedTopLevelTasksWithTheirContent() throws {
        let editor = makeEditor(list)
        let events = try editor.archiveCompletedTasks()

        XCTAssertEqual(events.map(\.event), [.archived, .archived, .archived])
        XCTAssertEqual(editor.document.allTasksRecursive.map(\.text),
                       ["Open", "Reopened", "Done subtask stays with its parent"])
        XCTAssertEqual(try String(contentsOf: archiveURL, encoding: .utf8), """
        # Archived 2026-10-30

        ## To Do
        - [x] Shipped
          Release notes are in the wiki
          - [ ] Leftover subtask

        ## To Do / Later
        - [x] Old idea

        ## Done
        - [x] Dark mode

        """)
    }

    func testAppendsToAnExistingArchive() throws {
        try "# Archived 2026-10-01\n\n## Done\n- [x] Earlier\n".write(to: archiveURL, atomically: true, encoding: .utf8)
        let editor = makeEditor("# Done\n\n- [x] Now\n")
        try editor.archiveCompletedTasks()
        let archive = try String(contentsOf: archiveURL, encoding: .utf8)
        XCTAssertTrue(archive.hasPrefix("# Archived 2026-10-01\n\n## Done\n- [x] Earlier\n\n# Archived 2026-10-30\n"), archive)
        XCTAssertTrue(archive.hasSuffix("- [x] Now\n"))
    }

    func testNothingToArchiveThrows() {
        let editor = makeEditor("# To Do\n\n- [ ] Open\n")
        XCTAssertThrowsError(try editor.archiveCompletedTasks()) {
            XCTAssertEqual($0 as? ListoEditorError, .nothingToArchive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testUndoRestoresBothFilesAndRedoReappliesThem() throws {
        let editor = makeEditor(list)
        try editor.archiveCompletedTasks()
        let archived = try String(contentsOf: archiveURL, encoding: .utf8)

        try editor.undo()
        XCTAssertEqual(editor.currentText, list)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path), "the archive it created is gone again")

        try editor.redo()
        XCTAssertEqual(try String(contentsOf: archiveURL, encoding: .utf8), archived)
        XCTAssertFalse(editor.currentText.contains("Dark mode"))
    }

    func testUndoKeepsWhatTheArchiveHeldBefore() throws {
        let earlier = "# Archived 2026-10-01\n\n## Done\n- [x] Earlier\n"
        try earlier.write(to: archiveURL, atomically: true, encoding: .utf8)
        let editor = makeEditor("# Done\n\n- [x] Now\n")
        try editor.archiveCompletedTasks()
        try editor.undo()
        XCTAssertEqual(try String(contentsOf: archiveURL, encoding: .utf8), earlier)
    }
}
