import AppKit
import XCTest
import TheineCore
@testable import Theine

/// The menu of the icon, which is Theine's interface, and the two cups. Nothing here shows a menu or touches the menu
/// bar: the items are built over a stand-in blocker and a clock of the test's own.
@MainActor
final class MenuTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// No note about the closed lid: the helper is in place, or the user has not said no.
    private let quiet = ClosedLidNote(isShown: false, isAsking: false, allow: {})

    private func makeAwake(_ clock: Clock = Clock()) -> Awake {
        Awake(blocker: StandInBlocker(), store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
              options: { Awake.Options() }, now: { clock.now }, boot: { 1 }, schedulesTicks: false)
    }

    private func items(_ awake: Awake) -> [NSMenuItem] {
        AppActions.menuItems(awake: awake, setKeepsDisplay: { _ in }, setKeepsAwakeWithLidClosed: { _ in }, closedLidNote: quiet)
    }

    /// What a click on the item does.
    private func choose(_ item: NSMenuItem) {
        _ = item.target?.perform(item.action)
    }

    func testTheMenuAtRest() throws {
        let items = items(makeAwake())
        XCTAssertEqual(items.map(\.title),
                       ["Включить", "Не гасить экран", "Не засыпать с закрытой крышкой", "Включить на", "", "Выключено"])
        // ⇧⌘T is a label: it works while the menu is open (a global shortcut is the user's own, see ShortcutTests).
        XCTAssertEqual(items[0].keyEquivalent, "t")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(items[1].state, .off, "the display goes dark as usual until the flag is set")
        XCTAssertNotNil(items[1].toolTip)
        XCTAssertEqual(items[2].state, .on, "the Mac stays awake with the lid closed unless the user says otherwise")
        XCTAssertTrue(items[2].toolTip?.contains("в сумку") == true, "the tooltip warns about the heat in a bag")
        XCTAssertTrue(items[4].isSeparatorItem)
        XCTAssertFalse(items[5].isEnabled, "the status line does nothing")
        let lengths = try XCTUnwrap(items[3].submenu)
        XCTAssertEqual(lengths.items.map(\.title),
                       ["Без ограничения", "5 минут", "15 минут", "30 минут", "1 час", "2 часа", "4 часа", "8 часов"])
        XCTAssertTrue(lengths.items.allSatisfy { $0.target != nil && $0.action != nil })
    }

    func testTheLengthsStartSessionsOfThatLength() throws {
        let clock = Clock()
        let awake = makeAwake(clock)
        let expected: [TimeInterval?] = [nil, 300, 900, 1800, 3600, 7200, 14400, 28800]
        let titles = try XCTUnwrap(items(awake)[3].submenu).items.map(\.title)
        for (index, seconds) in expected.enumerated() {
            // The menu is built anew at every click, as the icon does.
            let lengths = try XCTUnwrap(items(awake)[3].submenu)
            choose(lengths.items[index])
            XCTAssertTrue(awake.isOn, titles[index])
            XCTAssertEqual(awake.session?.ends, seconds.map { clock.now.addingTimeInterval($0) }, titles[index])
        }
    }

    func testTheFirstItemTurnsTheModeOnAndOff() {
        let clock = Clock()
        let awake = makeAwake(clock)
        choose(items(awake)[0])
        XCTAssertTrue(awake.isOn)
        XCTAssertNil(awake.session?.ends, "«Включить» has no time limit")
        var menu = items(awake)
        XCTAssertEqual(menu.map(\.title), ["Выключить", "Не гасить экран", "Не засыпать с закрытой крышкой", "Включить на", "",
                                           "Включено меньше минуты"])
        clock.now.addTimeInterval(12 * 60)
        XCTAssertEqual(items(awake).last?.title, "Включено 12 мин")
        choose(menu[0])
        XCTAssertFalse(awake.isOn)
        menu = items(awake)
        XCTAssertEqual(menu.first?.title, "Включить")
    }

    func testTheMenuShowsTheTimeLeft() {
        let clock = Clock()
        let awake = makeAwake(clock)
        awake.start(.hours(1))
        clock.now.addTimeInterval(20 * 60)
        XCTAssertEqual(items(awake).last?.title, "Осталось 40 мин")
    }

    // MARK: The flags «Не гасить экран» and «Не засыпать с закрытой крышкой»

    /// The flags with stand-ins for the preferences they set, and the blocker behind them.
    @MainActor private final class Flags {
        var keepsDisplay = false
        var keepsLidClosed = true
        let blocker = StandInBlocker()
        let clock = Clock()
        var note = ClosedLidNote(isShown: false, isAsking: false, allow: {})
        lazy var awake = Awake(blocker: blocker, store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
                               options: { [unowned self] in
                                   Awake.Options(keepsDisplayOn: keepsDisplay, keepsAwakeWithLidClosed: keepsLidClosed)
                               },
                               now: { [unowned self] in clock.now }, boot: { 1 }, schedulesTicks: false)

        func items() -> [NSMenuItem] {
            AppActions.menuItems(awake: awake, setKeepsDisplay: { [unowned self] in keepsDisplay = $0 },
                                 setKeepsAwakeWithLidClosed: { [unowned self] in keepsLidClosed = $0 }, closedLidNote: note)
        }
    }

    func testTheDisplayFlagShowsTheSettingAndChangesIt() {
        let flags = Flags()
        XCTAssertEqual(flags.items()[1].title, "Не гасить экран")
        XCTAssertEqual(flags.items()[1].state, .off)
        choose(flags.items()[1])
        XCTAssertTrue(flags.keepsDisplay)
        XCTAssertEqual(flags.items()[1].state, .on, "the menu is built anew at every click and shows the setting")
        choose(flags.items()[1])
        XCTAssertFalse(flags.keepsDisplay)
        XCTAssertEqual(flags.items()[1].state, .off)
        XCTAssertFalse(flags.awake.isOn, "the flag does not turn the mode on")
        XCTAssertEqual(flags.blocker.requests, [], "nothing is held while the mode is off")
    }

    func testTheDisplayFlagChangesWhatIsHeldAtOnceWhileTheModeIsOn() {
        let flags = Flags()
        flags.awake.start(.unlimited)
        XCTAssertEqual(flags.blocker.requests, [false], "without the flag only the system is held: the display goes dark")
        XCTAssertFalse(flags.blocker.holdsDisplay)
        choose(flags.items()[1])
        XCTAssertEqual(flags.blocker.requests, [false, true], "with the flag the display is held too, with no new start")
        XCTAssertTrue(flags.blocker.holdsDisplay)
        XCTAssertTrue(flags.awake.isOn)
        choose(flags.items()[1])
        XCTAssertEqual(flags.blocker.requests, [false, true, false])
        XCTAssertFalse(flags.blocker.holdsDisplay)
        XCTAssertTrue(flags.blocker.isHeld, "the system stays held either way")
    }

    func testAModeStartedWithTheDisplayFlagSetHoldsTheDisplayFromTheStart() {
        let flags = Flags()
        flags.keepsDisplay = true
        choose(flags.items()[0])
        XCTAssertEqual(flags.blocker.requests, [true])
        XCTAssertTrue(flags.blocker.holdsDisplay)
    }

    func testTheClosedLidFlagIsOnByDefaultAndAskedForWithTheMode() {
        let flags = Flags()
        choose(flags.items()[0])
        XCTAssertEqual(flags.blocker.closedLidRequests, [true], "the helper is asked from the start")
        XCTAssertTrue(flags.blocker.holdsClosedLid)
    }

    func testTheClosedLidFlagChangesWhatIsHeldAtOnceWhileTheModeIsOn() {
        let flags = Flags()
        flags.awake.start(.unlimited)
        choose(flags.items()[2])
        XCTAssertFalse(flags.keepsLidClosed)
        XCTAssertEqual(flags.items()[2].state, .off)
        XCTAssertEqual(flags.blocker.closedLidRequests, [true, false], "the request to the helper goes, with no new start")
        XCTAssertFalse(flags.blocker.holdsClosedLid)
        XCTAssertTrue(flags.blocker.isHeld, "the rest stays held")
        choose(flags.items()[2])
        XCTAssertEqual(flags.blocker.closedLidRequests, [true, false, true])
        XCTAssertTrue(flags.blocker.holdsClosedLid)
        XCTAssertEqual(flags.blocker.requests, [false, false, false], "the display flag stays as it was")
    }

    func testTheClosedLidFlagDoesNotTurnTheModeOn() {
        let flags = Flags()
        choose(flags.items()[2])
        XCTAssertFalse(flags.keepsLidClosed)
        XCTAssertFalse(flags.awake.isOn)
        XCTAssertEqual(flags.blocker.closedLidRequests, [])
    }

    // MARK: The note after a «Не сейчас» to the password

    func testAfterARefusalTheMenuSaysTheClosedLidDoesNotWorkAndOffersToAllow() {
        let flags = Flags()
        var allowed = 0
        flags.note = ClosedLidNote(isShown: true, isAsking: false, allow: { allowed += 1 })
        flags.awake.start(.unlimited)
        let items = flags.items()
        XCTAssertEqual(Array(items.map(\.title).suffix(3)),
                       ["Включено меньше минуты", "С закрытой крышкой не действует", "Разрешить…"])
        XCTAssertFalse(items[items.count - 2].isEnabled, "the note does nothing")
        XCTAssertNotNil(items.last?.toolTip)
        choose(items[items.count - 1])
        XCTAssertEqual(allowed, 1, "«Разрешить…» asks for the password again")
        XCTAssertTrue(flags.awake.isOn, "the mode runs without the helper all the same")
    }

    func testWhileThePasswordDialogIsOpenThereIsNothingToAllow() {
        let flags = Flags()
        flags.note = ClosedLidNote(isShown: true, isAsking: true, allow: {})
        XCTAssertEqual(flags.items().last?.title, "С закрытой крышкой не действует")
    }

    func testTheMenuKeepsTheFamilyItemsAfterTheActions() {
        let items = StatusItem.menu(actions: items(makeAwake())).items
        XCTAssertEqual(items.count, 6 + 1 + 5)
        XCTAssertTrue(items[6].isSeparatorItem)
        XCTAssertEqual(items[7].action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(items.last?.action, #selector(NSApplication.terminate(_:)))
    }

    func testTheAppIsBusyOnlyWhileTheHelperHoldsTheClosedLid() {
        XCTAssertTrue(AppActions.isBusy(modeIsOn: true, keepsAwakeWithLidClosed: true, helperInstalled: true),
                      "a restart would let a Mac with its lid closed fall asleep: an update waits")
        for (on, lid, helper) in [(false, true, true), (true, false, true), (true, true, false), (false, false, false)] {
            XCTAssertFalse(AppActions.isBusy(modeIsOn: on, keepsAwakeWithLidClosed: lid, helperInstalled: helper),
                           "the plain mode is saved and comes back, so an update need not wait for it: \(on) \(lid) \(helper)")
        }
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
