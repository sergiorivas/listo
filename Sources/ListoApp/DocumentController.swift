import Foundation
import ListoEngine

/// Ties a `ListoFileDocument` to the `ListoEngine`: owns the parsed tree,
/// the Modo App action wrappers, and the Modo Libre diff-at-save pipeline
/// (spec §03/§05).
///
/// Modo Libre used to run a live FSEvents watcher that diffed on every disk
/// write (including Cocoa's own autosave), which made it possible for our
/// own in-flight write to be misread as an external change. That's gone:
/// free text is only interpreted once, right when the user saves (Cmd+S,
/// the toolbar Save button, or leaving Modo Libre) — see `handleSave`.
@MainActor
final class DocumentController: ObservableObject {
    @Published private(set) var document: ListoDocument
    @Published var mode: EditMode = .app {
        didSet { modeChanged(from: oldValue) }
    }
    @Published var viewStyle: ViewStyle = .kanban
    /// The one selected task/subtask, à la Things — click any row to select
    /// it (independent of entering text-edit mode), then ⇥/⇧⇥ re-indents it
    /// without needing to first click into its text field. Shared here
    /// rather than per-view state so it survives switching between Kanban
    /// and Outline.
    @Published var selectedTaskID: UUID?
    @Published private(set) var logEvents: [LogEvent] = []
    @Published var errorMessage: String?

    private let fileDocument: ListoFileDocument
    private var editor: ListoEditor
    /// The text as of the last time it was interpreted — the last Modo
    /// Libre save (or mode switch), or the last Modo App action. The diff
    /// baseline for the next save.
    private var lastKnownText: String
    private var fileURL: URL?

    init(fileDocument: ListoFileDocument, fileURL: URL?) {
        self.fileDocument = fileDocument
        self.fileURL = fileURL
        let url = fileURL ?? DocumentController.scratchURL()
        self.editor = ListoEditor(fileURL: url, initialText: fileDocument.text, autoPersist: fileURL != nil)
        self.document = editor.document
        self.lastKnownText = fileDocument.text
        refreshLog()
        fileDocument.onWillSave = { [weak self] text in self?.handleSave(currentText: text) }
    }

    private static func scratchURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("untitled-\(UUID().uuidString).md")
    }

    /// Call when the document's real on-disk URL becomes known (first save
    /// of a brand-new document) so App Mode writes and the log sidecar
    /// start targeting the real file.
    func bindToFileURL(_ url: URL) {
        guard fileURL != url else { return }
        fileURL = url
        editor = ListoEditor(fileURL: url, initialText: fileDocument.text, autoPersist: true)
        document = editor.document
        lastKnownText = fileDocument.text
        refreshLog()
    }

    // MARK: - Mode / view style

    private func modeChanged(from oldValue: EditMode) {
        guard mode != oldValue else { return }
        if mode == .freeEdit {
            lastKnownText = fileDocument.text
        } else {
            // Leaving Modo Libre: interpret whatever changed since the last
            // save (or since entering Modo Libre, if never saved) so the
            // structured views and the log are caught up, same as an
            // explicit save would do.
            handleSave(currentText: fileDocument.text)
            editor.loadExternalText(fileDocument.text)
            document = editor.document
        }
    }

    // MARK: - Modo Libre: diff at save time

    /// The only place Modo Libre's free text gets interpreted: called via
    /// `ListoFileDocument.onWillSave` right before the document is
    /// persisted (Cmd+S, the toolbar Save button, or macOS autosave), and
    /// also when leaving Modo Libre. Computes "what changed since last
    /// time" once and logs it — no live watcher, no per-keystroke debounce.
    private func handleSave(currentText: String) {
        guard mode == .freeEdit else { return }
        let oldText = lastKnownText
        guard oldText != currentText else { return }
        lastKnownText = currentText
        editor.loadExternalText(currentText)
        document = editor.document

        let outcome = ListoDiffer.diff(fileName: editor.fileURL.lastPathComponent, oldText: oldText, newText: currentText)
        switch outcome {
        case .resolved(let events):
            for event in events { _ = try? editor.logWriter.append(event) }
            refreshLog()
        case .ambiguous(let guess, let old, let new):
            Task {
                do {
                    let client = Self.makeLLMClient()
                    let events = try await client.interpretDiff(fileName: editor.fileURL.lastPathComponent, oldText: old, newText: new)
                    await MainActor.run {
                        for event in events { _ = try? self.editor.logWriter.append(event) }
                        self.refreshLog()
                    }
                } catch {
                    await MainActor.run {
                        // No LLM available — log the fallback instead of
                        // guessing wrong or silently dropping the change.
                        _ = try? self.editor.logWriter.append(ListoDiffer.unresolvedChangeEvent(fileName: self.editor.fileURL.lastPathComponent))
                        _ = guess
                        self.refreshLog()
                    }
                }
            }
        }
    }

    private static func makeLLMClient() -> LLMClient {
        AnthropicLLMClient() ?? UnavailableLLMClient()
    }

    // MARK: - Modo App actions

    func addTask(text: String, toSectionID sectionID: UUID) {
        perform { try $0.addTask(text: text, toSectionID: sectionID) }
    }

    func toggle(taskID: UUID) {
        perform { try $0.toggle(taskID: taskID) }
    }

    func rename(taskID: UUID, newText: String) {
        perform(followSelectionFrom: taskID) { try $0.renameTask(taskID: taskID, newText: newText) }
    }

    func renameSection(sectionID: UUID, newTitle: String) {
        perform { try $0.renameSection(sectionID: sectionID, newTitle: newTitle) }
    }

    func setNote(taskID: UUID, note: String?) {
        perform { try $0.setNote(taskID: taskID, note: note) }
    }

    func indent(taskID: UUID) {
        // First item / already at max nesting are expected boundary
        // conditions reachable from a plain Tab keystroke — no-op instead
        // of an intrusive error alert.
        perform(followSelectionFrom: taskID, silencing: { $0 == .noPrecedingSibling || $0 == .maxDepthReached }) {
            try $0.indentTask(taskID: taskID)
        }
    }

    func outdent(taskID: UUID) {
        perform(followSelectionFrom: taskID, silencing: { $0 == .alreadyTopLevel }) {
            try $0.outdentTask(taskID: taskID)
        }
    }

    func move(taskID: UUID, toSectionID sectionID: UUID) {
        perform(followSelectionFrom: taskID) { try $0.moveTask(taskID: taskID, toSectionID: sectionID) }
    }

    func delete(taskID: UUID) {
        perform { try $0.deleteTask(taskID: taskID) }
    }

    func deleteSection(sectionID: UUID) {
        perform { try $0.deleteSection(sectionID: sectionID) }
    }

    /// - Parameter followSelectionFrom: pass the id the action was invoked
    ///   on for `renameTask`/`indentTask`/`outdentTask`/`moveTask` — those
    ///   give the task a new content/position-derived id (`StableID`), so
    ///   if it's also the current selection, `selectedTaskID` is moved to
    ///   `editor.lastActionTaskID` afterward. Otherwise a second action on
    ///   what still looks like the same selected row (another rename, an
    ///   outdent right after an indent, ...) would reuse the now-stale id
    ///   and throw `taskNotFound`.
    private func perform(
        followSelectionFrom taskID: UUID? = nil,
        silencing: (ListoEditorError) -> Bool = { _ in false },
        _ action: (ListoEditor) throws -> LogEvent
    ) {
        do {
            _ = try action(editor)
            document = editor.document
            lastKnownText = editor.currentText
            fileDocument.text = editor.currentText
            if let taskID, selectedTaskID == taskID, let newID = editor.lastActionTaskID {
                selectedTaskID = newID
            }
            refreshLog()
        } catch let error as ListoEditorError where silencing(error) {
            return
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func refreshLog() {
        logEvents = (try? editor.readLog()) ?? []
    }

    func exportLogText() -> String {
        logEvents.map { event in
            (try? String(data: JSONEncoder().encode(event), encoding: .utf8) ?? "") ?? ""
        }.joined(separator: "\n")
    }

    var logFileURL: URL { editor.logWriter.logFileURL }
}
