import XCTest
@testable import ListoEngine

final class ParserTests: XCTestCase {
    let sample = """
    # ahora
    - [ ] Revisar PR de auth
        Ver el hilo en GitHub
        ```
        npm test -- --watch
        ```
      - [ ] Verificar tests de login
    - [x] Responder a Marco

    # mas tarde
    - [ ] Migrar base de datos

    # backlog
    ## prioridad 2
    - [ ] Rediseñar onboarding
    ## prioridad 3
    - [ ] Investigar exportar a PDF
    """

    func testParsesTopLevelSections() {
        let doc = ListoParser.parse(sample)
        XCTAssertEqual(doc.sections.map(\.title), ["ahora", "mas tarde", "backlog"])
        XCTAssertEqual(doc.sections.map(\.level), [1, 1, 1])
    }

    func testParsesTasksAndState() {
        let doc = ListoParser.parse(sample)
        let ahora = doc.sections[0]
        XCTAssertEqual(ahora.tasks.count, 2)
        XCTAssertEqual(ahora.tasks[0].text, "Revisar PR de auth")
        XCTAssertEqual(ahora.tasks[0].state, .open)
        XCTAssertEqual(ahora.tasks[1].text, "Responder a Marco")
        XCTAssertEqual(ahora.tasks[1].state, .done)
    }

    func testParsesSubtaskViaTwoSpaceIndent() {
        let doc = ListoParser.parse(sample)
        let firstTask = doc.sections[0].tasks[0]
        XCTAssertEqual(firstTask.subtasks.count, 1)
        XCTAssertEqual(firstTask.subtasks[0].text, "Verificar tests de login")
    }

    func testNoteIsNotMistakenForSubtask() {
        let doc = ListoParser.parse(sample)
        let firstTask = doc.sections[0].tasks[0]
        XCTAssertNotNil(firstTask.note)
        XCTAssertTrue(firstTask.note!.contains("GitHub"))
        XCTAssertTrue(firstTask.note!.contains("npm test"))
        // The note's code fence must not be parsed as structure.
        XCTAssertEqual(firstTask.subtasks.count, 1)
    }

    func testParsesNestedSubsections() {
        let doc = ListoParser.parse(sample)
        let backlog = doc.sections[2]
        XCTAssertEqual(backlog.subsections.map(\.title), ["prioridad 2", "prioridad 3"])
        XCTAssertEqual(backlog.subsections[0].tasks.first?.text, "Rediseñar onboarding")
    }

    func testSectionPath() {
        let doc = ListoParser.parse(sample)
        let prioridad2 = doc.sections[2].subsections[0]
        XCTAssertEqual(doc.path(to: prioridad2), ["backlog", "prioridad 2"])
    }

    func testTabIndentAlsoWorks() {
        let text = "# ahora\n- [ ] Parent\n\t- [ ] Child\n"
        let doc = ListoParser.parse(text)
        XCTAssertEqual(doc.sections[0].tasks[0].subtasks.first?.text, "Child")
    }
}
