import IOKit.pwr_mgt
import XCTest
@testable import TheineCore

/// The mode, driven with a clock, a battery and a blocker of its own: nothing here keeps the Mac awake, apart from the
/// few milliseconds of the tests under «The system».
@MainActor
final class AwakeTests: XCTestCase {
    /// The world around an `Awake`: the assertion, the store, the clock, the battery, the options, the boot of the Mac.
    @MainActor private final class Rig {
        let blocker = StandInBlocker()
        let store = StandInStore()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var power = PowerState(percent: 80, onBattery: false)
        var options = Awake.Options()
        var boot: TimeInterval = 100
        var finished: [AwakeStop] = []
        var changes = 0
        private(set) var awake: Awake!

        init() {
            awake = makeAwake()
        }

        /// Another run of the app over the same store and the same Mac.
        func makeAwake() -> Awake {
            let awake = Awake(blocker: blocker, store: store, power: { [unowned self] in power },
                              options: { [unowned self] in options }, now: { [unowned self] in now },
                              boot: { [unowned self] in boot }, schedulesTicks: false)
            awake.onChange = { [unowned self] in changes += 1 }
            awake.onFinish = { [unowned self] in finished.append($0) }
            return awake
        }

        func advance(minutes: Double) {
            now.addTimeInterval(minutes * 60)
        }
    }

    // MARK: Turning on and off

    func testTurningOnHoldsTheMacAndSavesTheSession() {
        let rig = Rig()
        XCTAssertTrue(rig.awake.start(.unlimited))
        XCTAssertTrue(rig.awake.isOn)
        XCTAssertEqual(rig.blocker.requests, [false])
        XCTAssertTrue(rig.blocker.isHeld)
        XCTAssertEqual(rig.store.session, AwakeSession(started: rig.now, ends: nil, boot: 100))
        XCTAssertEqual(rig.changes, 1)
    }

    func testTurningOffByHandReleasesAndForgets() {
        let rig = Rig()
        rig.awake.start(.minutes(30))
        rig.awake.stop()
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertFalse(rig.blocker.isHeld)
        XCTAssertNil(rig.store.session)
        XCTAssertNil(rig.awake.lastStop)
        XCTAssertEqual(rig.finished, [], "turning off by hand makes no sound")
        XCTAssertEqual(rig.changes, 2)
    }

    func testToggleTurnsOnWithoutALimitAndOff() {
        let rig = Rig()
        rig.awake.toggle()
        XCTAssertEqual(rig.awake.session?.ends, nil)
        XCTAssertTrue(rig.awake.isOn)
        rig.awake.toggle()
        XCTAssertFalse(rig.awake.isOn)
    }

    func testAnotherLengthReplacesTheRunningSession() {
        let rig = Rig()
        rig.awake.start(.minutes(5))
        rig.advance(minutes: 1)
        rig.awake.start(.hours(2))
        XCTAssertEqual(rig.awake.session?.started, rig.now)
        XCTAssertEqual(rig.awake.session?.ends, rig.now.addingTimeInterval(7200))
        XCTAssertTrue(rig.blocker.isHeld)
    }

    func testTheSystemRefusingLeavesTheModeOff() {
        let rig = Rig()
        rig.blocker.refuses = true
        XCTAssertFalse(rig.awake.start(.unlimited))
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertNil(rig.store.session)
        XCTAssertEqual(rig.changes, 0)
    }

    // MARK: The time

    func testATimedSessionEndsWhenItsTimeComes() {
        let rig = Rig()
        rig.awake.start(.minutes(15))
        XCTAssertEqual(rig.store.session?.ends, rig.now.addingTimeInterval(900))
        rig.now.addTimeInterval(899)
        rig.awake.tick()
        XCTAssertTrue(rig.awake.isOn)
        XCTAssertEqual(rig.finished, [])
        rig.now.addTimeInterval(1)
        rig.awake.tick()
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertEqual(rig.awake.lastStop, .expired)
        XCTAssertEqual(rig.finished, [.expired])
        XCTAssertFalse(rig.blocker.isHeld)
        XCTAssertNil(rig.store.session)
    }

    func testASessionWithoutALimitNeverEndsByTheClock() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.advance(minutes: 60 * 24 * 7)
        rig.awake.tick()
        XCTAssertTrue(rig.awake.isOn)
    }

    func testATickWhileOffDoesNothing() {
        let rig = Rig()
        rig.awake.tick()
        rig.awake.optionsChanged()
        XCTAssertEqual(rig.changes, 0)
        XCTAssertEqual(rig.blocker.requests, [])
    }

    // MARK: The display

    func testTheDisplayOptionHoldsTheDisplayToo() {
        let rig = Rig()
        rig.options.keepsDisplayOn = true
        rig.awake.start(.unlimited)
        XCTAssertEqual(rig.blocker.requests, [true])
        XCTAssertTrue(rig.blocker.holdsDisplay)
    }

    func testChangingTheDisplayOptionWhileOnReplacesWhatIsHeld() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.options.keepsDisplayOn = true
        rig.awake.optionsChanged()
        XCTAssertTrue(rig.blocker.holdsDisplay)
        rig.awake.optionsChanged()
        XCTAssertEqual(rig.blocker.requests, [false, true], "the same option is not asked for twice")
        rig.options.keepsDisplayOn = false
        rig.awake.optionsChanged()
        XCTAssertEqual(rig.blocker.requests, [false, true, false])
        XCTAssertTrue(rig.blocker.isHeld)
    }

    // MARK: The closed lid

    func testTheClosedLidIsAskedForWithTheModeByDefault() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        XCTAssertEqual(rig.blocker.closedLidRequests, [true])
        XCTAssertTrue(rig.blocker.holdsClosedLid)
        rig.awake.stop()
        XCTAssertFalse(rig.blocker.holdsClosedLid, "the request goes with the mode")
    }

    func testChangingTheClosedLidOptionWhileOnChangesWhatIsHeld() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.options.keepsAwakeWithLidClosed = false
        rig.awake.optionsChanged()
        XCTAssertFalse(rig.blocker.holdsClosedLid)
        XCTAssertTrue(rig.blocker.isHeld)
        rig.awake.optionsChanged()
        XCTAssertEqual(rig.blocker.closedLidRequests, [true, false], "the same options are not asked for twice")
        XCTAssertTrue(rig.awake.isOn)
    }

    func testTheModeAsksAgainOnceTheHelperIsInstalled() {
        let rig = Rig()
        rig.awake.holdAgain()
        XCTAssertEqual(rig.blocker.closedLidRequests, [], "nothing is held while the mode is off")
        rig.awake.start(.minutes(30))
        let session = rig.awake.session
        rig.awake.holdAgain()
        XCTAssertEqual(rig.blocker.closedLidRequests, [true, true])
        XCTAssertEqual(rig.awake.session, session, "no new start")
        XCTAssertEqual(rig.changes, 1)
    }

    func testARestoredSessionAsksForTheClosedLidToo() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.awake.shutdown(forget: false)
        XCTAssertFalse(rig.blocker.holdsClosedLid)
        XCTAssertTrue(rig.makeAwake().restore())
        XCTAssertTrue(rig.blocker.holdsClosedLid)
    }

    // MARK: The restart

    func testASavedSessionComesBackAfterARestart() {
        let rig = Rig()
        rig.awake.start(.minutes(60))
        let saved = rig.store.session
        rig.advance(minutes: 10)
        rig.awake.shutdown(forget: false)
        XCTAssertFalse(rig.blocker.isHeld, "the assertion goes with the quitting app")
        XCTAssertEqual(rig.store.session, saved, "the session stays for the restart")

        let again = rig.makeAwake()
        XCTAssertTrue(again.restore())
        XCTAssertEqual(again.session, saved)
        XCTAssertTrue(rig.blocker.isHeld)
        XCTAssertEqual(again.statusText, "Осталось 50 мин")
    }

    func testASessionWithoutALimitComesBackWithItsStart() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.advance(minutes: 12)
        rig.awake.shutdown(forget: false)
        let again = rig.makeAwake()
        XCTAssertTrue(again.restore())
        XCTAssertEqual(again.statusText, "Включено 12 мин")
    }

    func testAnExpiredSessionDoesNotComeBack() {
        let rig = Rig()
        rig.awake.start(.minutes(5))
        rig.awake.shutdown(forget: false)
        rig.advance(minutes: 5)
        let again = rig.makeAwake()
        XCTAssertFalse(again.restore())
        XCTAssertFalse(again.isOn)
        XCTAssertNil(rig.store.session)
        XCTAssertFalse(rig.blocker.isHeld)
    }

    func testASessionOfAnotherBootDoesNotComeBack() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.awake.shutdown(forget: false)
        rig.boot = 101
        XCTAssertFalse(rig.makeAwake().restore())
        XCTAssertNil(rig.store.session)
    }

    func testQuittingByTheUserEndsTheModeForGood() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.awake.shutdown(forget: true)
        XCTAssertNil(rig.store.session)
        XCTAssertFalse(rig.makeAwake().restore())
    }

    func testNothingToRestoreAndNothingChanges() {
        let rig = Rig()
        XCTAssertFalse(rig.awake.restore())
        XCTAssertEqual(rig.changes, 0)
        XCTAssertEqual(rig.blocker.requests, [])
    }

    func testARestoredSessionKeepsTickingAndEnds() {
        let rig = Rig()
        rig.awake.start(.minutes(30))
        rig.awake.shutdown(forget: false)
        let again = rig.makeAwake()
        again.restore()
        rig.advance(minutes: 31)
        again.tick()
        XCTAssertFalse(again.isOn)
        XCTAssertEqual(rig.finished, [.expired])
        XCTAssertNil(rig.store.session)
    }

    // MARK: The battery

    func testALowBatteryForbidsTurningOn() {
        let rig = Rig()
        rig.power = PowerState(percent: 19, onBattery: true)
        XCTAssertTrue(rig.awake.isBlockedByBattery)
        XCTAssertFalse(rig.awake.start(.unlimited))
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertEqual(rig.blocker.requests, [])
        XCTAssertEqual(rig.finished, [.lowBattery])
        XCTAssertEqual(rig.awake.statusText, "Выключено, заряд ниже 20%")
    }

    func testTheBatteryAllowsTheModeAtTheLimitOnTheChargerAndWithoutTheOption() {
        let rig = Rig()
        for (state, stops) in [(PowerState(percent: 20, onBattery: true), true),
                               (PowerState(percent: 5, onBattery: false), true),
                               (PowerState(percent: 5, onBattery: true), false),
                               (PowerState(percent: nil, onBattery: false), true)] {
            rig.power = state
            rig.options.stopsOnLowBattery = stops
            XCTAssertFalse(rig.awake.isBlockedByBattery, "\(state) \(stops)")
            XCTAssertTrue(rig.awake.start(.unlimited), "\(state) \(stops)")
            rig.awake.stop()
        }
        XCTAssertEqual(rig.finished, [])
    }

    func testALowBatteryEndsARunningSession() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.power = PowerState(percent: 19, onBattery: false)
        rig.advance(minutes: 1)
        rig.awake.tick()
        XCTAssertTrue(rig.awake.isOn, "on the charger a low charge does not matter")
        rig.power = PowerState(percent: 19, onBattery: true)
        rig.awake.tick()
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertEqual(rig.awake.lastStop, .lowBattery)
        XCTAssertEqual(rig.finished, [.lowBattery])
        XCTAssertFalse(rig.blocker.isHeld)
        XCTAssertNil(rig.store.session)
    }

    func testTurningTheBatteryOptionOnInSettingsCanEndTheSession() {
        let rig = Rig()
        rig.power = PowerState(percent: 12, onBattery: true)
        rig.options.stopsOnLowBattery = false
        rig.awake.start(.unlimited)
        XCTAssertTrue(rig.awake.isOn)
        rig.options.stopsOnLowBattery = true
        rig.awake.optionsChanged()
        XCTAssertFalse(rig.awake.isOn)
        XCTAssertEqual(rig.finished, [.lowBattery])
    }

    func testALowBatteryAtRestoreForgetsTheSession() {
        let rig = Rig()
        rig.awake.start(.unlimited)
        rig.awake.shutdown(forget: false)
        rig.power = PowerState(percent: 10, onBattery: true)
        XCTAssertFalse(rig.makeAwake().restore())
        XCTAssertNil(rig.store.session)
    }

    // MARK: The real timer

    /// An `Awake` whose timer runs, every `poll` seconds; the run loop is turned by the test.
    private func ticking(_ rig: Rig, poll: TimeInterval) -> Awake {
        let awake = Awake(blocker: rig.blocker, store: rig.store, power: { [unowned rig] in rig.power },
                          options: { [unowned rig] in rig.options }, now: { Date() }, boot: { [unowned rig] in rig.boot },
                          schedulesTicks: true, pollInterval: poll)
        awake.onFinish = { [unowned rig] in rig.finished.append($0) }
        return awake
    }

    private func spin(until done: () -> Bool, seconds: TimeInterval = 3) {
        let limit = Date().addingTimeInterval(seconds)
        while !done(), Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testTheTimerLooksEveryThirtySecondsWhileTheModeHasNoLimit() throws {
        let rig = Rig()
        let awake = Awake(blocker: rig.blocker, store: rig.store, power: { [unowned rig] in rig.power }, now: { Date() })
        awake.start(.unlimited)
        defer { awake.stop() }
        let next = try XCTUnwrap(awake.nextLook)
        XCTAssertEqual(next.timeIntervalSinceNow, Awake.pollInterval, accuracy: 1)
        XCTAssertEqual(Awake.pollInterval, 30)
    }

    func testTheTimerEndsASessionWhoseTimeRunsOut() {
        let rig = Rig()
        let awake = ticking(rig, poll: 30)
        awake.start(.limited(0.3))
        spin { !awake.isOn }
        XCTAssertFalse(awake.isOn)
        XCTAssertEqual(rig.finished, [.expired])
        XCTAssertFalse(rig.blocker.isHeld)
    }

    func testTheTimerEndsTheModeWhenTheBatteryRunsLow() {
        let rig = Rig()
        let awake = ticking(rig, poll: 0.2)
        awake.start(.unlimited)
        spin(until: { false }, seconds: 0.5)
        XCTAssertTrue(awake.isOn, "the looks go on while the battery allows")
        XCTAssertNotNil(awake.nextLook)
        rig.power = PowerState(percent: 19, onBattery: true)
        spin { !awake.isOn }
        XCTAssertFalse(awake.isOn)
        XCTAssertEqual(rig.finished, [.lowBattery])
        XCTAssertNil(awake.nextLook, "no more looks once the mode is off")
    }

    // MARK: Words

    func testTheStatusLine() {
        let rig = Rig()
        XCTAssertEqual(rig.awake.statusText, "Выключено")
        rig.awake.start(.unlimited)
        XCTAssertEqual(rig.awake.statusText, "Включено меньше минуты")
        rig.advance(minutes: 12.9)
        XCTAssertEqual(rig.awake.statusText, "Включено 12 мин")
        rig.advance(minutes: 47.1)
        XCTAssertEqual(rig.awake.statusText, "Включено 1 ч")
        rig.advance(minutes: 65)
        XCTAssertEqual(rig.awake.statusText, "Включено 2 ч 5 мин")

        rig.awake.start(.minutes(60))
        XCTAssertEqual(rig.awake.statusText, "Осталось 1 ч")
        rig.advance(minutes: 20)
        XCTAssertEqual(rig.awake.statusText, "Осталось 40 мин")
        rig.advance(minutes: 39.5)
        XCTAssertEqual(rig.awake.statusText, "Осталось 1 мин")
        rig.advance(minutes: 0.5)
        XCTAssertEqual(rig.awake.statusText, "Осталось меньше минуты", "the tick that ends it has not come yet")
        rig.awake.tick()
        XCTAssertEqual(rig.awake.statusText, "Выключено, время вышло")
        rig.awake.start(.unlimited)
        rig.awake.stop()
        XCTAssertEqual(rig.awake.statusText, "Выключено")
    }

    // MARK: The system

    /// The assertions this very process holds, as the system lists them.
    private func ownAssertions() -> [[String: Any]] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let all = raw?.takeRetainedValue() as? [NSNumber: Any],
              let own = all[NSNumber(value: getpid())] as? [[String: Any]] else { return [] }
        return own
    }

    private func holds(_ type: String) -> Bool {
        ownAssertions().contains { $0["AssertType"] as? String == type && ($0["AssertName"] as? String)?.contains("Theine") == true }
    }

    /// The assertions last a few milliseconds.
    func testThePowerAssertionsAreSeenBySystemAndFollowTheDisplayOption() {
        let blocker = PowerAssertion()
        defer { blocker.release() }
        XCTAssertTrue(blocker.hold(display: false))
        XCTAssertTrue(holds("PreventUserIdleSystemSleep"))
        XCTAssertFalse(holds("PreventUserIdleDisplaySleep"))
        XCTAssertTrue(blocker.hold(display: true))
        XCTAssertTrue(holds("PreventUserIdleDisplaySleep"))
        XCTAssertTrue(holds("PreventUserIdleSystemSleep"), "the system stays held while the display is added")
        XCTAssertTrue(blocker.hold(display: true))
        XCTAssertEqual(ownAssertions().filter { ($0["AssertName"] as? String)?.contains("Theine") == true }.count, 2,
                       "each type is held once")
        XCTAssertTrue(blocker.hold(display: false))
        XCTAssertFalse(holds("PreventUserIdleDisplaySleep"))
        XCTAssertTrue(holds("PreventUserIdleSystemSleep"))
        blocker.release()
        XCTAssertFalse(holds("PreventUserIdleSystemSleep"))
        XCTAssertFalse(holds("PreventUserIdleDisplaySleep"))
    }

    func testThePowerSourceAndTheBootAreReadable() {
        let state = PowerSource.current()
        if let percent = state.percent { XCTAssertTrue((0...100).contains(percent)) }
        let boot = SystemBoot.time()
        XCTAssertGreaterThan(boot, 1_000_000_000)
        XCTAssertLessThan(boot, Date().timeIntervalSince1970)
    }

    func testTheSessionSurvivesTheRoundTripThroughPreferences() throws {
        let suite = "TheineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsSessionStore(defaults: defaults)
        XCTAssertNil(store.load())
        let session = AwakeSession(started: Date(timeIntervalSince1970: 1_800_000_000), ends: Date(timeIntervalSince1970: 1_800_003_600),
                                   boot: 42)
        store.save(session)
        XCTAssertEqual(store.load(), session)
        store.save(AwakeSession(started: session.started, ends: nil))
        XCTAssertNil(store.load()?.ends)
        store.save(nil)
        XCTAssertNil(store.load())
    }
}
