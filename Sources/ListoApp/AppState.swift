import Foundation

/// Modo App vs Modo Libre (spec §03) — orthogonal to `ViewStyle`.
enum EditMode: String, CaseIterable {
    case app
    case freeEdit
}

/// Kanban vs Outline (spec §04) — a display preference only, never changes
/// the underlying markdown.
enum ViewStyle: String, CaseIterable {
    case kanban
    case outline
}
