import SwiftUI
import AppKit

/// Modo Libre's raw markdown editor: a real `NSTextView` (not SwiftUI's
/// plain `TextEditor`) so the user gets native cursor/undo/spellcheck
/// behavior, plus lightweight syntax highlighting for headings and
/// checkboxes (ADR-001). Its font size tracks `AppSettings.baseFontSize`
/// (⌘+/⌘−ᐩ), same as every other text size in the app.
///
/// Just binds `text` — it doesn't interpret changes itself. That happens
/// once, at save time, in `DocumentController.handleSave`.
struct FreeEditView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.font = .monospacedSystemFont(ofSize: settings.baseFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.string = text
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.fontSize = settings.baseFontSize
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        var needsHighlight = false
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            needsHighlight = true
        }
        if context.coordinator.fontSize != settings.baseFontSize {
            context.coordinator.fontSize = settings.baseFontSize
            needsHighlight = true
        }
        if needsHighlight {
            context.coordinator.highlight(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fontSize: settings.baseFontSize)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var fontSize: Double
        weak var textView: NSTextView?

        init(text: Binding<String>, fontSize: Double) {
            self.text = text
            self.fontSize = fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            highlight(tv)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let nsText = storage.string as NSString
            let full = NSRange(location: 0, length: storage.length)
            let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

            storage.beginEditing()
            storage.setAttributes([
                .foregroundColor: NSColor.labelColor,
                .font: regularFont,
            ], range: full)

            if let headingRegex = try? NSRegularExpression(pattern: "^#{1,3} .*$", options: [.anchorsMatchLines]) {
                for match in headingRegex.matches(in: nsText as String, range: full) {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
                    storage.addAttribute(.font, value: boldFont, range: match.range)
                }
            }
            if let checkboxRegex = try? NSRegularExpression(pattern: "- \\[[ xX]\\]") {
                for match in checkboxRegex.matches(in: nsText as String, range: full) {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
                }
            }
            // A task line's trailing `!`/`!!`/`!!!` is its priority — the
            // one place the raw marker is shown (Kanban/Outline use an
            // indicator), coloured to match that indicator.
            if let priorityRegex = try? NSRegularExpression(pattern: "^[ \\t]*- \\[[ xX]\\].*[ \\t](!{1,3})[ \\t]*$", options: [.anchorsMatchLines]) {
                for match in priorityRegex.matches(in: nsText as String, range: full) {
                    let range = match.range(at: 1)
                    let color: NSColor = switch range.length {
                    case 1: .systemBlue
                    case 2: .systemOrange
                    default: .systemRed
                    }
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                    storage.addAttribute(.font, value: boldFont, range: range)
                }
            }
            storage.endEditing()
            textView.font = regularFont
        }
    }
}
