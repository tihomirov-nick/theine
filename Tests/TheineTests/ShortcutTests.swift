import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Theine

/// The shortcut that turns the mode on and off from any app: there is none until the user records one, it is kept in the
/// preferences, and the menu's ⇧⌘T is only a label.
@MainActor
final class ShortcutTests: XCTestCase {
    private func keyDown(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String = "t") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: UInt16(code))!
    }

    /// F19 with every modifier is nobody's combination.
    private let rare = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))

    func testThereIsNoGlobalShortcutByDefault() {
        XCTAssertNil(Preferences.shortcut)
        // Building the menu, with ⇧⌘T on «Включить», takes nothing from other apps.
        _ = StatusItem.menu()
        AppActions.applyShortcut()
        XCTAssertEqual(HotKeyCenter.shared.registeredCount, 0, "nothing is registered until the user records a shortcut")
    }

    func testTheMenuLabelIsAKeyOfTheOpenMenuOnly() {
        let item = AppActions.menuItems().first { $0.keyEquivalent == "t" }
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(HotKeyCenter.shared.registeredCount, 0)
    }

    /// The one test that registers a shortcut with the system, for a moment.
    func testTheRecordedShortcutIsRegisteredAndRemoved() {
        defer {
            Shortcut.save(nil, for: Preferences.shortcutKey)
            AppActions.applyShortcut()
        }
        Shortcut.save(rare, for: Preferences.shortcutKey)
        XCTAssertEqual(Preferences.shortcut, rare)
        AppActions.applyShortcut()
        XCTAssertEqual(HotKeyCenter.shared.registeredCount, 1)
        AppActions.applyShortcut()
        XCTAssertEqual(HotKeyCenter.shared.registeredCount, 1, "the new registration replaces the old one")
        Shortcut.save(nil, for: Preferences.shortcutKey)
        AppActions.applyShortcut()
        XCTAssertEqual(HotKeyCenter.shared.registeredCount, 0)
    }

    func testAShortcutNeedsCommandControlOrOptionUnlessItIsAFunctionKey() {
        XCTAssertEqual(Shortcut(event: keyDown(kVK_ANSI_T, [.command, .shift])),
                       Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertNotNil(Shortcut(event: keyDown(kVK_ANSI_T, [.control, .option])))
        XCTAssertNotNil(Shortcut(event: keyDown(kVK_F5, [], "")))
        XCTAssertNil(Shortcut(event: keyDown(kVK_ANSI_T, [.shift])), "a letter with Shift alone would take typing away")
        XCTAssertNil(Shortcut(event: keyDown(kVK_ANSI_T, [])))
    }

    func testTheShortcutIsShownWithItsModifiers() {
        XCTAssertTrue(rare.display.hasPrefix("⌃⌥⇧⌘"))
        XCTAssertEqual(Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0).display, "F5")
    }

    func testTheShortcutIsKeptInThePreferences() {
        let key = "TheineTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertNil(Shortcut.load(key, default: nil))
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))
        Shortcut.save(shortcut, for: key)
        XCTAssertEqual(Shortcut.load(key, default: nil), shortcut)
        Shortcut.save(nil, for: key)
        XCTAssertNil(Shortcut.load(key, default: nil), "removed by the user")
    }
}
