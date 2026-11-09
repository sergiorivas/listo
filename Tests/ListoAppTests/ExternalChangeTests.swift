import XCTest
import UniformTypeIdentifiers
import ListoEngine
@testable import ListoApp

final class ExternalChangeResolutionTests: XCTestCase {
    func testUnchangedDiskDoesNothingEvenWithPendingLocalEdits() {
        XCTAssertEqual(ExternalChange.resolve(disk: "a", baseline: "a", local: "a"), .none)
        XCTAssertEqual(ExternalChange.resolve(disk: "a", baseline: "a", local: "b"), .none)
    }

    func testOurOwnSaveLandingIsNotExternal() {
        XCTAssertEqual(ExternalChange.resolve(disk: "b", baseline: "a", local: "b"), .ownSave)
    }

    func testExternalEditWithNothingLocalIsAdopted() {
        XCTAssertEqual(ExternalChange.resolve(disk: "c", baseline: "a", local: "a"), .adoptDisk)
    }

    func testExternalEditPlusLocalEditsIsAConflict() {
        XCTAssertEqual(ExternalChange.resolve(disk: "c", baseline: "a", local: "b"), .conflict)
    }
}

@MainActor
final class ExternalChangeControllerTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("list.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeController(_ text: String) throws -> DocumentController {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let doc = ListoFileDocument()
        doc.text = text
        return DocumentController(fileDocument: doc, fileURL: url)
    }

    func testExternalEditIsAdoptedWhenNothingIsPending() throws {
        let c = try makeController("# Todo\n\n- [ ] A\n")
        try "# Todo\n\n- [ ] A\n- [ ] B\n".write(to: url, atomically: true, encoding: .utf8)
        c.checkForExternalChange()
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "B"])
        XCTAssertEqual(c.fileDocument.text, "# Todo\n\n- [ ] A\n- [ ] B\n")
        XCTAssertNil(c.pendingExternalText)
    }

    func testNoChangeLeavesDocumentAlone() throws {
        let c = try makeController("# Todo\n\n- [ ] A\n")
        c.checkForExternalChange()
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A"])
        XCTAssertNil(c.pendingExternalText)
    }

    func testConflictWaitsForTheUserAndReloadDiscardsLocalText() throws {
        let c = try makeController("# Todo\n\n- [ ] A\n")
        c.fileDocument.text = "# Todo\n\n- [ ] A local\n"      // unsaved local edit
        try "# Todo\n\n- [ ] A remote\n".write(to: url, atomically: true, encoding: .utf8)
        c.checkForExternalChange()
        XCTAssertEqual(c.pendingExternalText, "# Todo\n\n- [ ] A remote\n")
        XCTAssertEqual(c.fileDocument.text, "# Todo\n\n- [ ] A local\n", "nothing is discarded until the user chooses")
        c.reloadFromDisk()
        XCTAssertEqual(c.fileDocument.text, "# Todo\n\n- [ ] A remote\n")
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A remote"])
        XCTAssertNil(c.pendingExternalText)
    }

    func testKeepingLocalVersionStopsAskingAboutTheSameChange() throws {
        let c = try makeController("# Todo\n\n- [ ] A\n")
        c.fileDocument.text = "# Todo\n\n- [ ] A local\n"
        try "# Todo\n\n- [ ] A remote\n".write(to: url, atomically: true, encoding: .utf8)
        c.checkForExternalChange()
        c.keepLocalVersion()
        c.checkForExternalChange()
        XCTAssertNil(c.pendingExternalText)
        XCTAssertEqual(c.fileDocument.text, "# Todo\n\n- [ ] A local\n")
    }

    func testExternalReloadDropsUndoHistory() throws {
        let c = try makeController("# Todo\n\n- [ ] A\n")
        c.toggle(taskID: c.document.sections[0].tasks[0].id)
        XCTAssertTrue(c.canUndo)
        // What Cocoa does after the action: snapshot, then write the file.
        let saved = try c.fileDocument.snapshot(contentType: .plainText)
        try saved.write(to: url, atomically: true, encoding: .utf8)
        try "# Todo\n\n- [ ] Z\n".write(to: url, atomically: true, encoding: .utf8)
        c.checkForExternalChange()
        XCTAssertFalse(c.canUndo, "snapshots predate the outside edit")
    }
}

/// Tasks completed outside App Mode (another app, Free Mode) get the same
/// delayed move to the "Done" section as a checkbox click.
@MainActor
final class DoneMoveOutsideAppModeTests: XCTestCase {
    private var url: URL!
    private var savedDelay: Double = 0
    private let start = "# Todo\n\n- [ ] A\n- [x] Old\n\n# Done\n\n- [x] Z\n"

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("done-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("list.md")
        savedDelay = AppSettings.shared.doneMoveDelaySeconds
        AppSettings.shared.doneMoveDelaySeconds = 0.05
    }

    override func tearDownWithError() throws {
        AppSettings.shared.doneMoveDelaySeconds = savedDelay
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeController() throws -> DocumentController {
        try start.write(to: url, atomically: true, encoding: .utf8)
        let doc = ListoFileDocument()
        doc.text = start
        return DocumentController(fileDocument: doc, fileURL: url)
    }

    private func waitForDelay() {
        let done = expectation(description: "delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testTaskCheckedInAnotherAppMovesToDone() throws {
        let c = try makeController()
        try start.replacingOccurrences(of: "- [ ] A", with: "- [x] A").write(to: url, atomically: true, encoding: .utf8)
        c.checkForExternalChange()
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["A", "Old"], "not before the delay")
        waitForDelay()
        XCTAssertEqual(c.document.sections[0].tasks.map(\.text), ["Old"], "an already-done task elsewhere stays put")
        XCTAssertEqual(c.document.sections[1].tasks.map(\.text), ["Z", "A"])
    }

    func testTaskCheckedInFreeModeMovesAfterLeavingIt() throws {
        let c = try makeController()
        c.mode = .freeEdit
        c.fileDocument.text = start.replacingOccurrences(of: "- [ ] A", with: "- [x] A")
        waitForDelay()
        XCTAssertEqual(c.fileDocument.text, start.replacingOccurrences(of: "- [ ] A", with: "- [x] A"), "nothing moves while typing")
        c.mode = .app
        waitForDelay()
        XCTAssertEqual(c.document.sections[1].tasks.map(\.text), ["Z", "A"])
    }

    func testLeavingFreeModeWithoutSavingLogsTheChange() throws {
        let c = try makeController()
        c.mode = .freeEdit
        c.fileDocument.text = start.replacingOccurrences(of: "- [ ] A", with: "- [x] A")
        c.mode = .app
        XCTAssertTrue(c.logEvents.contains { $0.event == .completed && $0.text == "A" })
    }
}
