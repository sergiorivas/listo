import SwiftUI
import AppKit

/// The app's animation vocabulary — every animation goes through here so
/// they share timings and all switch off together under the system's
/// "Reduce motion" accessibility setting (each accessor returns `nil` then,
/// which SwiftUI treats as "no animation", so transitions and effects fall
/// back to instant changes).
///
/// Structural animations (rows entering/leaving/moving) are *not* applied
/// to the lists themselves — see `DocumentController.perform(animation:)`:
/// a task's id is derived from its content, so a rename gives the row a new
/// id, and an always-on animation would fade the row out and back in on
/// every rename. Only the actions that should animate opt in.
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Rows entering, leaving or changing place; column collapse.
    static var snappy: Animation? { reduceMotion ? nil : .snappy(duration: 0.28) }
    /// Small state changes: checking a task, a drop-target highlight.
    static var quick: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    /// Selection highlight following ↑/↓ or a click.
    static var selection: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.12) }
    /// The fade-out at the end of a `RowHighlight` flash.
    static var flashFade: Animation? { reduceMotion ? nil : .easeOut(duration: 0.5) }

    /// A task card/row, subtask row or note appearing or disappearing.
    static var rowTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    /// A whole column / section appearing or disappearing.
    static var sectionTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
    }
}

/// The checkbox glyph of a task row (Kanban and Outline share it): the
/// square/checkmark swap cross-fades, and checking a task off gives the
/// glyph a little bounce. Un-checking doesn't bounce — completing is the
/// moment worth marking.
struct TaskCheckboxIcon: View {
    let isDone: Bool
    @State private var bounce = 0

    var body: some View {
        Image(systemName: isDone ? "checkmark.square.fill" : "square")
            .foregroundStyle(isDone ? Color.accentColor : .secondary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: bounce)
            .onChange(of: isDone) { _, done in
                if done, !Motion.reduceMotion { bounce += 1 }
            }
    }
}

/// The selection highlight plus the brief "look here" flash used after a
/// row jumps somewhere (re-prioritised, moved, indented) —
/// `DocumentController.flashTaskID`. Replaces the plain
/// `.background(isSelected ? ... : .clear)` both views used; the colour and
/// (lack of) border are unchanged, it just fades instead of snapping.
struct RowHighlight: ViewModifier {
    let isSelected: Bool
    let isFlashing: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Color.accentColor.opacity(isSelected ? 0.22 : 0)
                    .animation(Motion.selection, value: isSelected)
            }
            .overlay {
                Color.accentColor.opacity(isFlashing ? 0.35 : 0)
                    .allowsHitTesting(false)
                    .animation(Motion.quick, value: isFlashing)
            }
    }
}

/// Highlight drawn over a column/section while a dragged task hovers over
/// it — the drop target feedback that used to be missing entirely.
struct DropTargetHighlight: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.12 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.8 : 0), lineWidth: 2)
                    )
                    .allowsHitTesting(false)
                    .animation(Motion.quick, value: isTargeted)
            }
    }
}

/// A quick "pop" — scale up, spring back — whenever `value` changes. Used
/// on counts (section badge, subtask progress) so a change elsewhere in the
/// column catches the eye. Stays at 1 under Reduce Motion.
struct PulseOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    var scale: CGFloat = 1.2

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: value) { view, s in
            view.scaleEffect(s)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(Motion.reduceMotion ? 1 : scale, duration: 0.1)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
        }
    }
}

/// `.plain`, plus a small press-down scale so icon buttons feel clicked.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.86 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension View {
    func pulse<Value: Equatable>(on value: Value, scale: CGFloat = 1.2) -> some View {
        modifier(PulseOnChange(value: value, scale: scale))
    }

    func rowHighlight(isSelected: Bool, isFlashing: Bool) -> some View {
        modifier(RowHighlight(isSelected: isSelected, isFlashing: isFlashing))
    }

    func dropTargetHighlight(_ isTargeted: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(DropTargetHighlight(isTargeted: isTargeted, cornerRadius: cornerRadius))
    }
}
