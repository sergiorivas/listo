import XCTest
import Carbon.HIToolbox
@testable import ListoApp

final class HotKeyShortcutTests: XCTestCase {
    func testNeedsCommandOptionOrControl() {
        XCTAssertTrue(HotKeyShortcut.defaultQuickAdd.isValid)
        XCTAssertTrue(HotKeyShortcut(keyCode: kVK_ANSI_K, modifiers: optionKey).isValid)
        XCTAssertFalse(HotKeyShortcut(keyCode: kVK_ANSI_K, modifiers: 0).isValid)
        XCTAssertFalse(HotKeyShortcut(keyCode: kVK_ANSI_K, modifiers: shiftKey).isValid)
    }

    func testModifiersPrintInMenuOrder() {
        let shortcut = HotKeyShortcut(keyCode: kVK_Space, modifiers: cmdKey | shiftKey | optionKey | controlKey)
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘Space")
    }
}
