import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A system-wide key combination as Carbon's `RegisterEventHotKey` wants it:
/// a virtual key code plus Carbon modifier bits (`cmdKey`, `optionKey`, …).
struct HotKeyShortcut: Equatable {
    var keyCode: Int
    var modifiers: Int

    /// ⌃⌥⌘T.
    static let defaultQuickAdd = HotKeyShortcut(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | cmdKey)

    /// A global shortcut needs ⌘, ⌥ or ⌃: a bare key (or ⇧ + key) would
    /// swallow ordinary typing in every app.
    var isValid: Bool { modifiers & (cmdKey | optionKey | controlKey) != 0 }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        self.init(keyCode: Int(event.keyCode), modifiers: carbon)
    }

    /// In the order macOS menus print them: ⌃⌥⇧⌘ then the key.
    var displayString: String {
        var result = ""
        if modifiers & controlKey != 0 { result += "⌃" }
        if modifiers & optionKey != 0 { result += "⌥" }
        if modifiers & shiftKey != 0 { result += "⇧" }
        if modifiers & cmdKey != 0 { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's label in the current keyboard layout (so it reads right on
    /// non-US layouts), via `UCKeyTranslate` with no modifiers.
    static func keyName(_ keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Settings control: shows the shortcut; click it, then press the new
/// combination. Esc cancels. While recording, the global hot key is
/// suspended, or pressing the current combination would open the panel
/// instead of reaching the recorder.
struct HotKeyRecorder: View {
    @Binding var shortcut: HotKeyShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("settings.hotKey.recording", "Presioná la combinación…") : shortcut.displayString)
                .monospacedDigit()
                .frame(minWidth: 110)
                .foregroundStyle(recording ? Color.accentColor : .primary)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        QuickAddController.shared.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let candidate = HotKeyShortcut(event: event)
            if candidate.keyCode == kVK_Escape && candidate.modifiers == 0 {
                stop()
            } else if candidate.isValid {
                shortcut = candidate
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        QuickAddController.shared.resumeHotKey()
    }
}
