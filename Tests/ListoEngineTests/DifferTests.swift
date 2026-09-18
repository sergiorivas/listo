import XCTest
@testable import ListoEngine

final class DifferTests: XCTestCase {
    func testSimpleCheckboxToggleIsResolved() {
        let old = "# ahora\n- [ ] Task A\n"
        let new = "# ahora\n- [x] Task A\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new)
        guard case .resolved(let events) = outcome else { return XCTFail("expected resolved") }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, .completed)
        XCTAssertEqual(events[0].interpretedBy, .heuristic)
        XCTAssertEqual(events[0].source, .freeEdit)
    }

    func testSingleNewLineIsResolved() {
        let old = "# ahora\n- [ ] Task A\n"
        let new = "# ahora\n- [ ] Task A\n- [ ] Task B\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new)
        guard case .resolved(let events) = outcome else { return XCTFail("expected resolved") }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, .created)
        XCTAssertEqual(events[0].text, "Task B")
    }

    func testSingleDeletionIsResolved() {
        let old = "# ahora\n- [ ] Task A\n- [ ] Task B\n"
        let new = "# ahora\n- [ ] Task A\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new)
        guard case .resolved(let events) = outcome else { return XCTFail("expected resolved") }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, .deleted)
        XCTAssertEqual(events[0].text, "Task B")
    }

    func testSingleMoveIsResolvedNotDeleteCreate() {
        let old = "# ahora\n- [ ] Migrar base de datos\n\n# mas tarde\n"
        let new = "# ahora\n\n# mas tarde\n- [ ] Migrar base de datos\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new)
        guard case .resolved(let events) = outcome else { return XCTFail("expected resolved") }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, .movedSection)
        if case .move(let from, let to) = events[0].sectionPath {
            XCTAssertEqual(from, ["ahora"])
            XCTAssertEqual(to, ["mas tarde"])
        } else {
            XCTFail("expected move section_path")
        }
    }

    func testMultipleSimultaneousMovesAreAmbiguous() {
        let old = "# ahora\n- [ ] A\n- [ ] B\n\n# mas tarde\n- [ ] C\n"
        let new = "# ahora\n- [ ] C\n\n# mas tarde\n- [ ] A\n- [ ] B\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: old, newText: new)
        guard case .ambiguous(let guess, let oldOut, let newOut) = outcome else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(oldOut, old)
        XCTAssertEqual(newOut, new)
        XCTAssertFalse(guess.isEmpty)
    }

    func testNoChangeProducesNoEvents() {
        let text = "# ahora\n- [ ] Task A\n"
        let outcome = ListoDiffer.diff(fileName: "f.md", oldText: text, newText: text)
        guard case .resolved(let events) = outcome else { return XCTFail("expected resolved") }
        XCTAssertTrue(events.isEmpty)
    }

    func testUnresolvedFallbackEvent() {
        let event = ListoDiffer.unresolvedChangeEvent(fileName: "f.md", reason: "no API key configured")
        XCTAssertEqual(event.event, .unresolved)
        XCTAssertEqual(event.interpretedBy, .heuristic)
        XCTAssertEqual(event.text, "no API key configured")
    }
}
