import AppKit
import Foundation
import SwiftUI
import ListoEngine

extension DocumentController {
    /// User-requested addition: checking off a top-level task, when the
    /// document has a section whose title contains "Done"/"Completed"/
    /// "Finished" (case-insensitive, any depth), bumps it to the end of
    /// that section after `AppSettings.doneMoveDelaySeconds` — a beat to
    /// see the checkmark land before the row jumps away, rather than an
    /// instant relocate. `0` disables the feature entirely.
    ///
    /// Everything is re-validated when the delay fires (not just captured
    /// up front): the task could have been unchecked, deleted, or reindented
    /// under a parent in the meantime, and the section could have been
    /// renamed or deleted — any of which just cancels the move rather than
    /// acting on stale state. A subtask is never moved (`moveTask` only
    /// supports top-level tasks — see the two-level model).
    func scheduleDoneMoveIfNeeded(forTaskID taskID: UUID) {
        let delay = AppSettings.shared.doneMoveDelaySeconds
        guard delay > 0,
              let task = document.allTasksRecursive.first(where: { $0.id == taskID }),
              task.state == .done,
              document.location(of: task)?.parent == nil,
              let doneSection = Self.doneSection(in: document)
        else { return }
        let doneSectionID = doneSection.id

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let task = self.document.allTasksRecursive.first(where: { $0.id == taskID }),
                  task.state == .done,
                  self.document.location(of: task)?.parent == nil,
                  let liveDoneSection = self.document.allSectionsRecursive.first(where: { $0.id == doneSectionID }),
                  liveDoneSection.tasks.last?.id != taskID
            else { return }
            self.move(taskID: taskID, toSectionID: doneSectionID)
        }
    }

    /// First section (any nesting depth, document order) whose title
    /// contains one of the "done" keywords — a loose match, not an exact
    /// name, so "Done ✅" or "Completed tasks" both qualify.
    private static func doneSection(in document: ListoDocument) -> ListoSection? {
        let keywords = ["done", "completed", "finished"]
        return document.allSectionsRecursive.first { section in
            let title = section.title.lowercased()
            return keywords.contains { title.contains($0) }
        }
    }
}
