import XCTest
import ListoEngine
@testable import ListoApp

/// Done-section names, the undo banner, the move flight key and the
/// priority/view shortcuts.
@MainActor
final class ImprovementsTests: XCTestCase {
    private func makeController(_ text: String) -> DocumentController {
        let doc = ListoFileDocument()
        doc.text = text
        return DocumentController(fileDocument: doc, fileURL: nil)
    }

    private func task(_ controller: DocumentController, _ text: String) -> ListoTask {
        controller.document.allTasksRecursive.first { $0.text == text }!
    }

    // MARK: - Done section names

    func testDoneSectionMatchesSpanishNameIgnoringCaseAndAccents() {
        let doc = ListoParser.parse("# Por hacer\n\n- [ ] A\n\n# Terminádo ✅\n")
        let keywords = AppSettings.keywords(from: AppSettings.defaultDoneSectionNames)
        XCTAssertEqual(DocumentController.doneSection(in: doc, keywords: keywords)?.title, "Terminádo ✅")
    }

    func testDoneSectionUsesCustomNames() {
        let doc = ListoParser.parse("# Inbox\n\n# Shipped\n")
        XCTAssertNil(DocumentController.doneSection(in: doc, keywords: ["done"]))
        XCTAssertEqual(DocumentController.doneSection(in: doc, keywords: AppSettings.keywords(from: " shipped , ,"))?.title, "Shipped")
    }

    func testDoneSectionWithNoNamesMatchesNothing() {
        let doc = ListoParser.parse("# Done\n")
        XCTAssertNil(DocumentController.doneSection(in: doc, keywords: AppSettings.keywords(from: " , ")))
    }

    // MARK: - Undo banner

    func testDeleteShowsUndoToastAndUndoFromToastRestores() {
        let c = makeController("# Todo\n\n- [ ] Buy milk\n- [ ] B\n")
        c.delete(taskID: task(c, "Buy milk").id)
        XCTAssertNotNil(c.undoToast)
        XCTAssertTrue(c.undoToast!.message.contains("Buy milk"))
        c.undoFromToast()
        XCTAssertNil(c.undoToast)
        XCTAssertTrue(c.document.allTasksRecursive.contains { $0.text == "Buy milk" })
    }

    func testDeletingBlankTaskShowsNoToast() {
        let c = makeController("# Todo\n\n- [ ] \n- [ ] B\n")
        let blank = c.document.allTasksRecursive.first { $0.text.isEmpty }!
        c.delete(taskID: blank.id)
        XCTAssertNil(c.undoToast)
    }

    func testSplitShowsToast() {
        let c = makeController("# Todo\n\n- [ ] P\n  - [ ] S1\n  - [ ] S2\n")
        c.split(taskID: task(c, "P").id)
        XCTAssertNotNil(c.undoToast)
    }

    func testUndoDismissesToast() {
        let c = makeController("# Todo\n\n- [ ] A\n")
        c.delete(taskID: task(c, "A").id)
        c.undo()
        XCTAssertNil(c.undoToast)
    }

    func testDeleteSectionShowsToast() {
        let c = makeController("# Todo\n\n- [ ] A\n\n# Later\n")
        c.deleteSection(sectionID: c.document.sections[1].id)
        XCTAssertNotNil(c.undoToast)
    }

    // MARK: - Move flight key

    func testFlightKeyDefaultsToOwnID() {
        let c = makeController("# Todo\n\n- [ ] A\n")
        let id = task(c, "A").id
        XCTAssertEqual(c.flightKey(for: id), id)
    }

    func testMoveToAdjacentSectionKeysNewCardOnOldID() throws {
        try XCTSkipIf(Motion.reduceMotion, "no flight under Reduce Motion")
        let c = makeController("# Todo\n\n- [ ] A\n\n# Done\n")
        let oldID = task(c, "A").id
        c.selectedTaskID = oldID
        c.moveToAdjacentSection(taskID: oldID, direction: 1)
        let newID = task(c, "A").id
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(c.flightKey(for: newID), oldID)
        XCTAssertEqual(c.selectedTaskID, newID)
    }

    // MARK: - Shortcuts

    func testSetPriorityOfSelection() {
        let c = makeController("# Todo\n\n- [ ] A\n")
        c.selectedTaskID = task(c, "A").id
        c.setPriorityOfSelection(.high)
        XCTAssertEqual(task(c, "A").priority, .high)
        XCTAssertTrue(c.fileDocument.text.contains("- [ ] A !!!"))
        c.setPriorityOfSelection(.none)
        XCTAssertEqual(task(c, "A").priority, TaskPriority.none)
    }

    func testShowSwitchesBackToAppMode() {
        let c = makeController("# Todo\n")
        c.mode = .freeEdit
        c.show(.outline)
        XCTAssertEqual(c.mode, .app)
        XCTAssertEqual(c.viewStyle, .outline)
    }
}
