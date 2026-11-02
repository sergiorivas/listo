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

    private func event(_ id: String) -> LogEvent {
        LogEvent(file: "backlog.md", event: .completed, taskID: id, sectionPath: nil, text: id, source: .app, interpretedBy: .userAction)
    }

    func testReadAllPicksUpLaterAppendsIncrementally() throws {
        let writer = LogWriter(documentURL: fileURL)
        try writer.append(event("t_1"))
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_1"])
        try writer.append(event("t_2"))
        try writer.append(event("t_3"))
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_1", "t_2", "t_3"])
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_1", "t_2", "t_3"])
    }

    func testReadAllSeesAppendsFromAnotherWriter() throws {
        let reader = LogWriter(documentURL: fileURL)
        try reader.append(event("t_1"))
        _ = try reader.readAll()
        try LogWriter(documentURL: fileURL).append(event("t_2"))
        XCTAssertEqual(try reader.readAll().map(\.taskID), ["t_1", "t_2"])
    }

    func testReadAllLeavesAnUnfinishedLastLineForLater() throws {
        let writer = LogWriter(documentURL: fileURL)
        try writer.append(event("t_1"))
        let logURL = LogWriter.logFileURL(for: fileURL)
        let line = String(data: try JSONEncoder().encode(event("t_2")), encoding: .utf8)!
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        handle.write(Data(line[..<half].utf8))
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_1"])
        handle.write(Data((line[half...] + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_1", "t_2"])
    }

    func testReadAllStartsOverWhenTheFileIsReplaced() throws {
        let writer = LogWriter(documentURL: fileURL)
        try writer.append(event("t_1"))
        try writer.append(event("t_2"))
        _ = try writer.readAll()
        let logURL = LogWriter.logFileURL(for: fileURL)
        let replacement = String(data: try JSONEncoder().encode(event("t_9")), encoding: .utf8)! + "\n"
        try replacement.write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try writer.readAll().map(\.taskID), ["t_9"])
        try FileManager.default.removeItem(at: logURL)
        XCTAssertEqual(try writer.readAll().count, 0)
    }
}
