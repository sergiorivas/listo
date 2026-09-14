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

    /// A note is stored dedented — only the one indent unit that
    /// structurally marks it as "this task's note" is stripped, not any
    /// extra indentation the note author added on top of that.
    func testNoteIsStoredDedented() {
        let text = "# ahora\n- [ ] Task A\n  line one\n  line two\n"
        let task = ListoParser.parse(text).sections[0].tasks[0]
        XCTAssertEqual(task.note, "line one\nline two")
    }

    func testNoteWithExtraIndentationKeepsIt() {
        // Task's note sits one unit in (2 spaces); the note author added a
        // further nested line (4 spaces) — only the structural unit is
        // stripped, leaving 2 spaces of the note's own content.
        let text = "# ahora\n- [ ] Task A\n  top\n    nested\n"
        let task = ListoParser.parse(text).sections[0].tasks[0]
        XCTAssertEqual(task.note, "top\n  nested")
    }

    /// Parsing a serialized document must reproduce the same (dedented)
    /// note — the round trip that broke before the dedent fix.
    func testNoteRoundTripsThroughSerializer() {
        let original = ListoParser.parse("# ahora\n- [ ] Task A\n  a note\n")
        let task = original.sections[0].tasks[0]
        XCTAssertEqual(task.note, "a note")

        let serialized = ListoSerializer.serialize(original)
        let reparsed = ListoParser.parse(serialized)
        XCTAssertEqual(reparsed.sections[0].tasks[0].note, "a note")
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

    func testTaskIDIsStableAcrossReparsesOfUnrelatedEdits() {
        let before = "# ahora\n- [ ] Task A\n- [ ] Task B\n"
        let after = "# ahora\n- [x] Task A\n- [ ] Task B\n" // Task B untouched
        let idBefore = ListoParser.parse(before).sections[0].tasks[1].id
        let idAfter = ListoParser.parse(after).sections[0].tasks[1].id
        XCTAssertEqual(idBefore, idAfter, "an edit to a sibling task must not change this task's id")
    }

    func testSectionIDIsStableAcrossReparsesOfUnrelatedEdits() {
        let before = "# ahora\n- [ ] Task A\n\n# mas tarde\n"
        let after = "# ahora\n- [ ] Task A\n- [ ] Task B\n\n# mas tarde\n"
        let idBefore = ListoParser.parse(before).sections[1].id
        let idAfter = ListoParser.parse(after).sections[1].id
        XCTAssertEqual(idBefore, idAfter, "adding a task to a sibling section must not change this section's id")
    }

    func testDuplicateTextGetsDistinctStableIDs() {
        let text = "# ahora\n- [ ] Same text\n- [ ] Same text\n"
        let doc = ListoParser.parse(text)
        XCTAssertNotEqual(doc.sections[0].tasks[0].id, doc.sections[0].tasks[1].id)
        // And reparsing preserves that same pairing (first stays first).
        let reparsed = ListoParser.parse(text)
        XCTAssertEqual(doc.sections[0].tasks[0].id, reparsed.sections[0].tasks[0].id)
        XCTAssertEqual(doc.sections[0].tasks[1].id, reparsed.sections[0].tasks[1].id)
    }

    func testTabIndentAlsoWorks() {
        let text = "# ahora\n- [ ] Parent\n\t- [ ] Child\n"
        let doc = ListoParser.parse(text)
        XCTAssertEqual(doc.sections[0].tasks[0].subtasks.first?.text, "Child")
    }
}
