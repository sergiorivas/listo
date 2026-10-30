import Foundation
import SwiftUI
import ListoEngine

/// Which Outline sections are collapsed (accordion-style), per document —
/// pure presentation like `KanbanLayoutStore`, so it lives in UserDefaults
/// and never touches the file. Separate from Kanban's collapsed columns on
/// purpose: folding a column on the board shouldn't fold the list too.
///
/// Keyed by the document's path plus the section's id. A section's
/// `StableID` is derived from its level, title and parent, so it's the same
/// across launches and tells apart two subsections with the same title
/// under different parents (Kanban's title-only key can't); renaming a
/// section starts it expanded again.
final class OutlineLayoutStore: ObservableObject {
    static let shared = OutlineLayoutStore()

    @Published private var collapsed: Set<String>

    private static let defaultsKey = "listo.outline.collapsedSections"

    private init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isCollapsed(documentKey: String, sectionID: UUID) -> Bool {
        collapsed.contains(key(documentKey, sectionID))
    }

    func setCollapsed(_ isCollapsed: Bool, documentKey: String, sectionID: UUID) {
        let k = key(documentKey, sectionID)
        if isCollapsed {
            collapsed.insert(k)
        } else {
            collapsed.remove(k)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.defaultsKey)
    }

    private func key(_ documentKey: String, _ sectionID: UUID) -> String {
        "\(documentKey)#\(sectionID.uuidString)"
    }
}
