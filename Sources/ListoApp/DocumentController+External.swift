import AppKit
import SwiftUI
import Foundation
import ListoEngine

extension DocumentController {
    /// Call when the app or this window comes to the front: picks up edits
    /// made to the file from outside. A silent reload when there's nothing of
    /// ours to lose, otherwise `pendingExternalText` asks the user.
    func checkForExternalChange() {
        guard let fileURL, pendingExternalText == nil,
              let disk = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        switch ExternalChange.resolve(disk: disk, baseline: diskBaseline, local: fileDocument.text) {
        case .none:
            break
        case .ownSave:
            diskBaseline = disk
        case .adoptDisk:
            adoptExternalText(disk)
        case .conflict:
            pendingExternalText = disk
        }
    }

    /// The user chose the file's version over their unsaved changes.
    func reloadFromDisk() {
        guard let disk = pendingExternalText else { return }
        adoptExternalText(disk)
    }

    /// The user chose to keep their version; the next save overwrites the
    /// file's.
    func keepLocalVersion() {
        guard let disk = pendingExternalText else { return }
        diskBaseline = disk
        pendingExternalText = nil
        syncModificationDate()
    }

    private func adoptExternalText(_ disk: String) {
        fileDocument.text = disk
        diskBaseline = disk
        lastKnownText = disk
        pendingExternalText = nil
        editor.loadExternalText(disk)
        withAnimation(Motion.snappy) {
            document = editor.document
            let live = Set(document.allTasksRecursive.map(\.id))
            if let id = selectedTaskID, !live.contains(id) { selectedTaskID = nil }
            if let id = editingTaskID, !live.contains(id) { editingTaskID = nil }
        }
        syncModificationDate()
        refreshLog()
    }

    /// Tell Cocoa we've seen the file's current version, so its own
    /// "modified by another application" prompt doesn't fire on the next
    /// save for a change we've already dealt with.
    private func syncModificationDate() {
        guard let fileURL,
              let nsDocument = NSDocumentController.shared.document(for: fileURL),
              let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return }
        nsDocument.fileModificationDate = date
    }
}
