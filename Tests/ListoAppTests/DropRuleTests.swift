import XCTest
import ListoEngine
@testable import ListoApp

final class DropRuleTests: XCTestCase {
    private func doc(_ text: String) -> ListoDocument { ListoParser.parse(text) }
    private func task(_ d: ListoDocument, _ text: String) -> ListoTask { d.allTasksRecursive.first { $0.text == text }! }
    private func place(_ d: ListoDocument, _ dragged: String, _ target: String, _ fraction: Double, subtasks: Bool = false) -> DropPlacement? {
        DropRule.placement(dragged: task(d, dragged), target: task(d, target), in: d, fraction: fraction, targetShowsSubtasks: subtasks)
    }

    func testTopMiddleBottomOfAPlainTaskRow() {
        let d = doc("# T\n\n- [ ] A\n- [ ] B\n")
        XCTAssertEqual(place(d, "A", "B", 0.1), .before)
        XCTAssertEqual(place(d, "A", "B", 0.5), .asSubtask)
        XCTAssertEqual(place(d, "A", "B", 0.9), .after)
    }

    func testBottomOfARowWithSubtasksMeansInside() {
        let d = doc("# T\n\n- [ ] A\n- [ ] B\n  - [ ] b1\n")
        XCTAssertEqual(place(d, "A", "B", 0.9, subtasks: true), .asSubtask)
    }

    func testDifferentPriorityInSameListOnlyAllowsNesting() {
        let d = doc("# T\n\n- [ ] A\n- [ ] B !!!\n")
        XCTAssertEqual(place(d, "A", "B", 0.1), .asSubtask, "no visible reorder, so nest instead")
        XCTAssertNil(place(doc("# T\n\n- [ ] A\n  n\n- [ ] B !!!\n"), "A", "B", 0.1), "has a note: can't nest either")
    }

    func testDifferentPriorityAcrossSectionsIsAllowed() {
        let d = doc("# One\n\n- [ ] A\n\n# Two\n\n- [ ] B !!!\n")
        XCTAssertEqual(place(d, "A", "B", 0.1), .before)
    }

    func testTaskWithContentCanStillBeReordered() {
        let d = doc("# T\n\n- [ ] A\n  - [ ] a1\n- [ ] B\n")
        XCTAssertEqual(place(d, "A", "B", 0.4), .before, "can't nest, so falls back to the nearer edge")
        XCTAssertEqual(place(d, "A", "B", 0.6), .after)
    }

    func testSubtaskRowsSplitInHalves() {
        let d = doc("# T\n\n- [ ] P\n  - [ ] s1\n  - [ ] s2\n")
        XCTAssertEqual(place(d, "s1", "s2", 0.2), .before)
        XCTAssertEqual(place(d, "s1", "s2", 0.8), .after)
    }

    func testTopLevelTaskCannotLandBetweenSubtasks() {
        let d = doc("# T\n\n- [ ] P\n  - [ ] s1\n- [ ] Q\n")
        XCTAssertNil(place(d, "Q", "s1", 0.2))
    }

    func testSubtaskOnItsOwnParentIsRefused() {
        let d = doc("# T\n\n- [ ] P\n  - [ ] s1\n")
        XCTAssertNil(place(d, "s1", "P", 0.5))
        XCTAssertNil(place(d, "P", "s1", 0.5), "onto its own subtask")
        XCTAssertNil(place(d, "P", "P", 0.5))
    }

    func testSubtaskCanMoveUnderAnotherTask() {
        let d = doc("# T\n\n- [ ] P\n  - [ ] s1\n- [ ] Q\n")
        XCTAssertEqual(place(d, "s1", "Q", 0.5), .asSubtask)
    }

    func testMultiSelectionNestsOnlyIfEveryTaskCan() {
        let d = doc("# T\n\n- [ ] A\n- [ ] B\n- [ ] C\n  n\n- [ ] D\n")
        let pair = [task(d, "A"), task(d, "B")]
        XCTAssertEqual(DropRule.placement(dragging: pair, primary: pair[0], target: task(d, "D"), in: d, fraction: 0.5, targetShowsSubtasks: false), .asSubtask)
        let withNote = [task(d, "A"), task(d, "C")]
        XCTAssertNil(DropRule.placement(dragging: withNote, primary: withNote[0], target: task(d, "D"), in: d, fraction: 0.5, targetShowsSubtasks: false),
                     "C has a note, so it can't become a subtask")
    }

    func testMultiSelectionCantDropOntoItself() {
        let d = doc("# T\n\n- [ ] A\n- [ ] B\n- [ ] C\n")
        let pair = [task(d, "A"), task(d, "B")]
        XCTAssertNil(DropRule.placement(dragging: pair, primary: pair[0], target: task(d, "B"), in: d, fraction: 0.1, targetShowsSubtasks: false))
    }
}
