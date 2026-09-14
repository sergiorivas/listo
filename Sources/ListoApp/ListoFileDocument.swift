import SwiftUI
import UniformTypeIdentifiers
import ListoEngine

/// The thin SwiftUI-facing side of a document: just the raw markdown text,
/// so `DocumentGroup`'s own save/autosave/undo machinery keeps working
/// exactly as it would for a plain text file. All Listo-specific behavior
/// (parsing, App Mode edits, the Modo Libre diff-at-save, the log) lives in
/// `DocumentController`, built on top of this in `ContentView`.
final class ListoFileDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    }
    static var writableContentTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    }

    @Published var text: String

    /// Set by `DocumentController` to run its Modo Libre diff/log pipeline
    /// exactly when the document is about to be saved — Cmd+S, the toolbar
    /// Save button, or macOS autosave all funnel through `snapshot(_:)`.
    var onWillSave: ((String) -> Void)?

    init() {
        text = ListoFileDocument.initialTemplate(for: AppSettings.shared.language.resolvedCode)
    }

    static func initialTemplate(for languageCode: String) -> String {
        languageCode == "en" ? "# Today\n\n# Later\n" : "# Hoy\n\n# Luego\n"
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func snapshot(contentType: UTType) throws -> String {
        onWillSave?(text)
        return text
    }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
