import XCTest
import AppKit
import ListoEngine
@testable import ListoApp

/// Moving into a collapsed Kanban column leaves it collapsed; the stored
/// window frame survives and is placed back on a screen.
@MainActor
final class CollapsedColumnAndWindowTests: XCTestCase {
    private var collapsedKeys: [(String, String)] = []

    override func tearDown() {
        for (doc, title) in collapsedKeys {
            KanbanLayoutStore.shared.setCollapsed(false, documentKey: doc, sectionTitle: title)
        }
        collapsedKeys = []
        super.tearDown()
    }

    private func makeController(_ text: String) -> DocumentController {
        let doc = ListoFileDocument()
        doc.text = text
        return DocumentController(fileDocument: doc, fileURL: nil)
    }

    private func task(_ controller: DocumentController, _ text: String) -> ListoTask {
        controller.document.allTasksRecursive.first { $0.text == text }!
    }

    private func collapse(_ title: String, in c: DocumentController) {
        KanbanLayoutStore.shared.setCollapsed(true, documentKey: c.documentKey, sectionTitle: title)
        collapsedKeys.append((c.documentKey, title))
    }

    private func isCollapsed(_ title: String, in c: DocumentController) -> Bool {
        KanbanLayoutStore.shared.isCollapsed(documentKey: c.documentKey, sectionTitle: title)
    }

    private let board = "# Todo\n\n- [ ] A\n- [ ] B\n\n# Done\n\n- [x] Z\n"

    // MARK: - Collapsed columns

    func testKeyboardMoveIntoCollapsedColumnKeepsItCollapsed() {
        let c = makeController(board)
        collapse("Done", in: c)
        c.selectedTaskID = task(c, "A").id
        c.moveToAdjacentSection(taskID: task(c, "A").id, direction: 1)
        XCTAssertTrue(c.document.sections[1].tasks.contains { $0.text == "A" }, "the task still moves")
        XCTAssertTrue(isCollapsed("Done", in: c))
        XCTAssertNil(c.selectedTaskID, "selection would open the column, so it is dropped")
    }

    func testMoveToCollapsedSectionKeepsItCollapsed() {
        let c = makeController(board)
        collapse("Done", in: c)
        c.selectedTaskID = task(c, "A").id
        c.move(taskID: task(c, "A").id, toSectionID: c.document.sections[1].id)
        XCTAssertTrue(c.document.sections[1].tasks.contains { $0.text == "A" })
        XCTAssertNil(c.selectedTaskID)
    }

    func testDropOntoTaskInCollapsedColumnKeepsItCollapsed() {
        let c = makeController(board)
        collapse("Done", in: c)
        c.selectedTaskID = task(c, "A").id
        c.drop(taskID: task(c, "A").id, onto: task(c, "Z").id, placement: .after)
        XCTAssertTrue(c.document.sections[1].tasks.contains { $0.text == "A" })
        XCTAssertNil(c.selectedTaskID)
    }

    func testBatchMoveIntoCollapsedColumnDropsMultiSelection() {
        let c = makeController(board)
        collapse("Done", in: c)
        c.selectedTaskID = task(c, "A").id
        c.extendSelection(direction: 1)
        c.moveToAdjacentSection(taskID: task(c, "B").id, direction: 1)
        XCTAssertEqual(c.document.sections[1].tasks.count, 3)
        XCTAssertNil(c.selectedTaskID)
        XCTAssertTrue(c.multiSelectedIDs.isEmpty)
    }

    func testMoveIntoExpandedColumnKeepsSelection() {
        let c = makeController(board)
        c.selectedTaskID = task(c, "A").id
        c.moveToAdjacentSection(taskID: task(c, "A").id, direction: 1)
        XCTAssertEqual(c.selectedTaskID, task(c, "A").id)
    }

    func testOutlineMoveKeepsSelectionEvenIfKanbanColumnCollapsed() {
        let c = makeController(board)
        collapse("Done", in: c)
        c.viewStyle = .outline
        c.selectedTaskID = task(c, "A").id
        c.move(taskID: task(c, "A").id, toSectionID: c.document.sections[1].id)
        XCTAssertEqual(c.selectedTaskID, task(c, "A").id, "Outline has no columns to hide it")
    }

    // MARK: - Window frame

    func testWindowFrameRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "listo.tests.windowframe"))
        defer { defaults.removePersistentDomain(forName: "listo.tests.windowframe") }
        XCTAssertNil(WindowFrameStore.load(from: defaults))
        let frame = NSRect(x: 120, y: 80, width: 1100, height: 700)
        WindowFrameStore.save(frame, to: defaults)
        XCTAssertEqual(WindowFrameStore.load(from: defaults), frame)
    }

    func testFrameOnScreenIsKept() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowFrameStore.placement(of: frame, screens: [screen]), frame)
    }

    func testFrameOffAllScreensKeepsSizeAndCentres() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 3000, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowFrameStore.placement(of: frame, screens: [screen]),
                       NSRect(x: 320, y: 150, width: 800, height: 600))
    }

    func testFrameLargerThanScreenShrinksWhenOffScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: -5000, y: 0, width: 2560, height: 1400)
        XCTAssertEqual(WindowFrameStore.placement(of: frame, screens: [screen]), screen)
    }
}
