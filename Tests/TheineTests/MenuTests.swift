import AppKit
import XCTest
import TheineCore
@testable import Theine

/// The menu of the icon, which is Theine's interface, and the two cups. Nothing here shows a menu or touches the menu
/// bar: the items are built over a stand-in power assertion and a clock of the test's own.
@MainActor
final class MenuTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeAwake(_ clock: Clock = Clock()) -> Awake {
        Awake(blocker: StandInBlocker(), store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
              options: { Awake.Options() }, now: { clock.now }, boot: { 1 }, schedulesTicks: false)
    }

    /// What a click on the item does.
    private func choose(_ item: NSMenuItem) {
        _ = item.target?.perform(item.action)
    }

    func testTheMenuAtRest() throws {
        let items = AppActions.menuItems(awake: makeAwake())
        XCTAssertEqual(items.map(\.title), ["Включить", "Не гасить экран", "Включить на", "", "Выключено"])
        // ⇧⌘T is a label: it works while the menu is open (a global shortcut is the user's own, see ShortcutTests).
        XCTAssertEqual(items[0].keyEquivalent, "t")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(items[1].state, .off, "the display goes dark as usual until the flag is set")
        XCTAssertNotNil(items[1].toolTip)
        XCTAssertTrue(items[3].isSeparatorItem)
        XCTAssertFalse(items[4].isEnabled, "the status line does nothing")
        let lengths = try XCTUnwrap(items[2].submenu)
        XCTAssertEqual(lengths.items.map(\.title),
                       ["Без ограничения", "5 минут", "15 минут", "30 минут", "1 час", "2 часа", "4 часа", "8 часов"])
        XCTAssertTrue(lengths.items.allSatisfy { $0.target != nil && $0.action != nil })
    }

    func testTheLengthsStartSessionsOfThatLength() throws {
        let clock = Clock()
        let awake = makeAwake(clock)
        let expected: [TimeInterval?] = [nil, 300, 900, 1800, 3600, 7200, 14400, 28800]
        let titles = try XCTUnwrap(AppActions.menuItems(awake: awake)[2].submenu).items.map(\.title)
        for (index, seconds) in expected.enumerated() {
            // The menu is built anew at every click, as the icon does.
            let lengths = try XCTUnwrap(AppActions.menuItems(awake: awake)[2].submenu)
            choose(lengths.items[index])
            XCTAssertTrue(awake.isOn, titles[index])
            XCTAssertEqual(awake.session?.ends, seconds.map { clock.now.addingTimeInterval($0) }, titles[index])
        }
    }

    func testTheFirstItemTurnsTheModeOnAndOff() {
        let clock = Clock()
        let awake = makeAwake(clock)
        choose(AppActions.menuItems(awake: awake)[0])
        XCTAssertTrue(awake.isOn)
        XCTAssertNil(awake.session?.ends, "«Включить» has no time limit")
        var items = AppActions.menuItems(awake: awake)
        XCTAssertEqual(items.map(\.title), ["Выключить", "Не гасить экран", "Включить на", "", "Включено меньше минуты"])
        clock.now.addTimeInterval(12 * 60)
        XCTAssertEqual(AppActions.menuItems(awake: awake).last?.title, "Включено 12 мин")
        choose(items[0])
        XCTAssertFalse(awake.isOn)
        items = AppActions.menuItems(awake: awake)
        XCTAssertEqual(items.first?.title, "Включить")
    }

    func testTheMenuShowsTheTimeLeft() {
        let clock = Clock()
        let awake = makeAwake(clock)
        awake.start(.hours(1))
        clock.now.addTimeInterval(20 * 60)
        XCTAssertEqual(AppActions.menuItems(awake: awake).last?.title, "Осталось 40 мин")
    }

    // MARK: The flag «Не гасить экран»

    /// The flag with a stand-in for the preference it sets, and the blocker behind it.
    @MainActor private final class Flag {
        var keepsDisplay = false
        let blocker = StandInBlocker()
        let clock = Clock()
        lazy var awake = Awake(blocker: blocker, store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
                               options: { [unowned self] in Awake.Options(keepsDisplayOn: keepsDisplay) },
                               now: { [unowned self] in clock.now }, boot: { 1 }, schedulesTicks: false)

        func items() -> [NSMenuItem] {
            AppActions.menuItems(awake: awake, setKeepsDisplay: { [unowned self] in keepsDisplay = $0 })
        }
    }

    func testTheFlagShowsTheSettingAndChangesIt() {
        let flag = Flag()
        XCTAssertEqual(flag.items()[1].title, "Не гасить экран")
        XCTAssertEqual(flag.items()[1].state, .off)
        choose(flag.items()[1])
        XCTAssertTrue(flag.keepsDisplay)
        XCTAssertEqual(flag.items()[1].state, .on, "the menu is built anew at every click and shows the setting")
        choose(flag.items()[1])
        XCTAssertFalse(flag.keepsDisplay)
        XCTAssertEqual(flag.items()[1].state, .off)
        XCTAssertFalse(flag.awake.isOn, "the flag does not turn the mode on")
        XCTAssertEqual(flag.blocker.requests, [], "nothing is held while the mode is off")
    }

    func testTheFlagChangesTheHeldAssertionAtOnceWhileTheModeIsOn() {
        let flag = Flag()
        flag.awake.start(.unlimited)
        XCTAssertEqual(flag.blocker.requests, [false], "without the flag only the system is held: the display goes dark")
        XCTAssertFalse(flag.blocker.holdsDisplay)
        choose(flag.items()[1])
        XCTAssertEqual(flag.blocker.requests, [false, true], "with the flag the display is held too, with no new start")
        XCTAssertTrue(flag.blocker.holdsDisplay)
        XCTAssertTrue(flag.awake.isOn)
        choose(flag.items()[1])
        XCTAssertEqual(flag.blocker.requests, [false, true, false])
        XCTAssertFalse(flag.blocker.holdsDisplay)
        XCTAssertTrue(flag.blocker.isHeld, "the system stays held either way")
    }

    func testAModeStartedWithTheFlagSetHoldsTheDisplayFromTheStart() {
        let flag = Flag()
        flag.keepsDisplay = true
        choose(flag.items()[0])
        XCTAssertEqual(flag.blocker.requests, [true])
        XCTAssertTrue(flag.blocker.holdsDisplay)
    }

    func testTheMenuKeepsTheFamilyItemsAfterTheActions() {
        let items = StatusItem.menu(actions: AppActions.menuItems(awake: makeAwake())).items
        XCTAssertEqual(items.count, 5 + 1 + 5)
        XCTAssertTrue(items[5].isSeparatorItem)
        XCTAssertEqual(items[6].action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(items.last?.action, #selector(NSApplication.terminate(_:)))
    }

    func testTheAppIsNeverBusy() {
        XCTAssertFalse(AppActions.isBusy, "the mode is saved and comes back, so an update need not wait for it")
    }

    // MARK: The cups

    /// The icon drawn four times larger.
    private func render(_ image: NSImage) -> NSBitmapImageRep {
        let width = Int(image.size.width * 4), height = Int(image.size.height * 4)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The alpha at a point of the cup's box (100 units square), found through the same placement the icon draws with.
    private func alpha(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let point = CGPoint(x: x, y: y).applying(Glyph.menuPlacement(bounds: Theine.bounds, scale: 4))
        return rep.colorAt(x: Int(point.x * 4), y: Int(point.y * 4))?.alphaComponent ?? -1
    }

    private func ink(_ rep: NSBitmapImageRep) -> Int {
        (0..<rep.pixelsWide).reduce(0) { total, x in total + (0..<rep.pixelsHigh).filter { rep.colorAt(x: x, y: $0)!.alphaComponent > 0.5 }.count }
    }

    /// The user's two samples: both cups are solid, with a ring for a handle. The full one has a thin dark ring just inside
    /// the rim and the drink, a solid oval, within it; the empty one has a dark oval in the rim and no drink.
    func testTheCupIsFullWhileTheModeIsOnAndEmptyWhileItIsOff() {
        let resting = render(MenuBarIcon.image(awake: false)), awake = render(MenuBarIcon.image(awake: true))
        XCTAssertGreaterThan(ink(resting), 1500, "the empty cup is drawn")
        XCTAssertGreaterThan(ink(awake), ink(resting), "the full cup has the drink on top of it")
        for (name, cup) in [("empty", resting), ("full", awake)] {
            XCTAssertEqual(alpha(cup, 45, 75), 1, accuracy: 0.01, "\(name): the body under the rim is solid")
            XCTAssertEqual(alpha(cup, 45, 18), 1, accuracy: 0.01, "\(name): the rim is a solid band")
            XCTAssertEqual(alpha(cup, 45, 25), 0, accuracy: 0.01, "\(name): dark inside the rim, the ring of the full cup")
            XCTAssertEqual(alpha(cup, 86.3, 59.5), 0, accuracy: 0.01, "\(name): the handle is a ring with a hole")
            XCTAssertEqual(alpha(cup, 86.3 + 9, 59.5), 1, accuracy: 0.01, "\(name): the handle's line")
        }
        XCTAssertEqual(alpha(resting, 45, 37), 0, accuracy: 0.01, "the empty cup is dark where the drink would be")
        XCTAssertEqual(alpha(awake, 45, 37), 1, accuracy: 0.01, "the drink is a solid oval")
    }

    func testTheDotOfAnUpdateIsDrawnOnEitherCup() {
        for awake in [false, true] {
            XCTAssertNotEqual(ink(render(MenuBarIcon.image(badge: true, awake: awake))),
                              ink(render(MenuBarIcon.image(awake: awake))), "awake: \(awake)")
        }
    }
}
