import XCTest
@testable import ListoApp

final class TaskLineContinuationTests: XCTestCase {
    private func resolve(_ line: String, at cursor: Int? = nil) -> TaskLineContinuation {
        TaskLineContinuation.resolve(line: line, cursor: cursor ?? (line as NSString).length)
    }

    func testTaskLineContinuesWithEmptyCheckbox() {
        XCTAssertEqual(resolve("- [ ] Open search y otro embedding"), .continueWith("- [ ] "))
    }

    func testDoneTaskContinuesWithOpenCheckbox() {
        XCTAssertEqual(resolve("- [x] Done thing"), .continueWith("- [ ] "))
    }

    func testSubtaskKeepsIndentation() {
        XCTAssertEqual(resolve("  - [ ] Subtask"), .continueWith("  - [ ] "))
        XCTAssertEqual(resolve("\t- [X] Subtask"), .continueWith("\t- [ ] "))
    }

    func testCursorMidLineStillContinues() {
        XCTAssertEqual(resolve("- [ ] Buy milk", at: 9), .continueWith("- [ ] "))
    }

    func testEmptyCheckboxEndsList() {
        XCTAssertEqual(resolve("- [ ] "), .endList)
        XCTAssertEqual(resolve("  - [ ]"), .endList)
    }

    func testCursorInsidePrefixIsPlainNewline() {
        XCTAssertEqual(resolve("- [ ] Task", at: 0), .none)
        XCTAssertEqual(resolve("- [ ] Task", at: 3), .none)
    }

    func testNonTaskLinesArePlainNewline() {
        XCTAssertEqual(resolve("# Heading"), .none)
        XCTAssertEqual(resolve("  A note line"), .none)
        XCTAssertEqual(resolve("- plain bullet"), .none)
        XCTAssertEqual(resolve(""), .none)
    }
}
