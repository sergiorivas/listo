import Foundation
import SwiftUI

/// Per-document Kanban column layout — width and collapsed state — kept
/// outside `ListoDocument`/the markdown file entirely (same spirit as
/// `StableID`'s in-memory-only ids): resizing or collapsing a column is
/// pure presentation, not content, so it has no business touching the
/// file's text or its diff/log pipeline.
///
/// Keyed by the document's file path plus the section's title, the same
/// "identity via title" `StableID` already relies on — renaming a column
/// just starts it fresh at the default width/expanded instead of trying to
/// carry a stale value over.
final class KanbanLayoutStore: ObservableObject {
    static let shared = KanbanLayoutStore()

    static let defaultColumnWidth: CGFloat = 340
    static let minColumnWidth: CGFloat = 220
    static let maxColumnWidth: CGFloat = 640
    static let collapsedColumnWidth: CGFloat = 44

    @Published private var widths: [String: Double]
    @Published private var collapsed: Set<String>

    private enum Keys {
        static let widths = "listo.kanban.columnWidths"
        static let collapsed = "listo.kanban.collapsedColumns"
    }

    private init() {
        let defaults = UserDefaults.standard
        widths = (defaults.dictionary(forKey: Keys.widths) as? [String: Double]) ?? [:]
        collapsed = Set(defaults.stringArray(forKey: Keys.collapsed) ?? [])
    }

    func width(documentKey: String, sectionTitle: String) -> CGFloat {
        widths[key(documentKey, sectionTitle)].map { CGFloat($0) } ?? Self.defaultColumnWidth
    }

    func setWidth(_ width: CGFloat, documentKey: String, sectionTitle: String) {
        let clamped = min(max(width, Self.minColumnWidth), Self.maxColumnWidth)
        widths[key(documentKey, sectionTitle)] = Double(clamped)
        UserDefaults.standard.set(widths, forKey: Keys.widths)
    }

    func isCollapsed(documentKey: String, sectionTitle: String) -> Bool {
        collapsed.contains(key(documentKey, sectionTitle))
    }

    func setCollapsed(_ isCollapsed: Bool, documentKey: String, sectionTitle: String) {
        let k = key(documentKey, sectionTitle)
        if isCollapsed {
            collapsed.insert(k)
        } else {
            collapsed.remove(k)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Keys.collapsed)
    }

    private func key(_ documentKey: String, _ sectionTitle: String) -> String {
        "\(documentKey)#\(sectionTitle)"
    }
}
