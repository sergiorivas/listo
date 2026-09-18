import AppKit
import SwiftUI

/// `Color` itself isn't reliably round-trippable through `UserDefaults`, so
/// `AppSettings`'s user-picked section background colors are stored as
/// `#RRGGBB` strings instead — good enough since these are always applied
/// at a fixed opacity by the caller (`KanbanColumn`), never with a custom
/// alpha of their own.
extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let rgb = UInt32(sanitized, radix: 16) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >> 8) / 255,
            blue: Double(rgb & 0x0000FF) / 255
        )
    }

    var hexString: String {
        let nsColor = (NSColor(self).usingColorSpace(.deviceRGB)) ?? NSColor(self)
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
