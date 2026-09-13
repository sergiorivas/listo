import XCTest
@testable import ListoEngine

final class LogWriterTests: XCTestCase {
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

    func testLogFileIsHiddenSidecar() {
        let logURL = LogWriter.logFileURL(for: fileURL)
        XCTAssertEqual(logURL.lastPathComponent, ".backlog.listo.jsonl")
    }

    func testAppendAndReadRoundTrip() throws {
        let writer = LogWriter(documentURL: fileURL)
        let e1 = LogEvent(
            file: "backlog.md", event: .created, taskID: "t_1", sectionPath: .path(["ahora"]),
            text: "Revisar PR", source: .app, interpretedBy: .userAction
        )
        let e2 = LogEvent(
            file: "backlog.md", event: .movedSection, taskID: "t_2",
            sectionPath: .move(from: ["ahora"], to: ["mas tarde"]),
            text: "Migrar base de datos", source: .freeEdit, interpretedBy: .llm
        )
        try writer.append(e1)
        try writer.append(e2)

        let events = try writer.readAll()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].taskID, "t_1")
        XCTAssertEqual(events[0].sectionPath, .path(["ahora"]))
        XCTAssertEqual(events[1].sectionPath, .move(from: ["ahora"], to: ["mas tarde"]))
    }

    func testOneJSONObjectPerLine() throws {
        let writer = LogWriter(documentURL: fileURL)
        try writer.append(LogEvent(file: "backlog.md", event: .completed, taskID: "t_1", sectionPath: nil, text: "X", source: .app, interpretedBy: .userAction))
        try writer.append(LogEvent(file: "backlog.md", event: .reopened, taskID: "t_1", sectionPath: nil, text: "X", source: .app, interpretedBy: .userAction))
        let contents = try String(contentsOf: LogWriter.logFileURL(for: fileURL), encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }
}
