import AppKit
import XCTest
@testable import Theine

/// The family's menu bar standard. Nothing here touches the menu bar: the menu is built, never shown.
@MainActor
final class AppTests: XCTestCase {
    func testTheIconIsATemplateImage22PointsHigh() {
        for badge in [false, true] {
            let image = MenuBarIcon.image(badge: badge)
            XCTAssertEqual(image.size.height, 22)
            XCTAssertEqual(image.size, MenuBarIcon.canvas)
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testTheMenuEndsWithTheFamilyItems() {
        let items = StatusItem.menu().items
        let tail = Array(items.suffix(5))
        XCTAssertEqual(tail.map(\.isSeparatorItem), [false, false, false, true, false])
        XCTAssertEqual(tail[0].action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(tail[0].keyEquivalent, ",")
        XCTAssertEqual(tail[1].action, #selector(AppDelegate.checkForUpdates(_:)))
        XCTAssertEqual(tail[2].action, #selector(AppDelegate.showAbout(_:)))
        XCTAssertEqual(tail[4].action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(tail[4].keyEquivalent, "q")
        // The app's own actions come first, a separator after them.
        let actions = AppActions.menuItems().count
        XCTAssertEqual(items.count, actions + (actions > 0 ? 1 : 0) + 5)
    }
}
