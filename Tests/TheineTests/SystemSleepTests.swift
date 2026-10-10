import AppKit
import IOKit.pwr_mgt
import XCTest
import TheineCore
import TheineHelperCore
@testable import Theine

/// The whole chain on this Mac, in the test's own process: a click in the menu, `Awake`, the real blocker, and what
/// `pmset -g assertions` shows for this process. The assertions last a moment. The request to the helper goes to a
/// folder of the test's own, and the screen saver pulse is a stand-in: nothing reaches the real helper, SleepDisabled
/// or the user's display.
@MainActor
final class SystemSleepTests: XCTestCase {
    /// The types of the assertions this process holds under Theine's names, as pmset lists them.
    private func pmsetAssertions() -> Set<String> {
        let output = shell("/usr/bin/pmset", ["-g", "assertions"]).output
        let own = "pid \(getpid())("
        return Set(output.split(separator: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(own), line.contains("Theine") else { return nil }
            return ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "UserIsActive"].first { line.contains(" \($0) ") }
        })
    }

    private func choose(_ item: NSMenuItem) {
        _ = item.target?.perform(item.action)
    }

    func testTheMenuHoldsTheMacTheWayPmsetSeesIt() throws {
        let folder = TemporaryFolder()
        let requests = folder.folder("Requests")
        var beats = 0
        let pulse = UserActivityPulse(every: 3600, displayIsAwake: { true }, declare: { _ in beats += 1 })
        let blocker = SystemSleepBlocker(requests: requests, pulse: pulse)
        var keepsDisplay = false, keepsLidClosed = true
        let awake = Awake(blocker: blocker, store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
                          options: { Awake.Options(keepsDisplayOn: keepsDisplay, keepsAwakeWithLidClosed: keepsLidClosed) },
                          schedulesTicks: false)
        defer { awake.shutdown(forget: true) }
        func items() -> [NSMenuItem] {
            AppActions.menuItems(awake: awake, setKeepsDisplay: { keepsDisplay = $0 }, setKeepsAwakeWithLidClosed: { keepsLidClosed = $0 },
                                 closedLidNote: ClosedLidNote(isShown: false, isAsking: false, allow: {}))
        }
        let request = "\(getuid())"

        XCTAssertEqual(pmsetAssertions(), [])
        choose(items()[0])
        XCTAssertTrue(awake.isOn)
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep"], "«Включить»: the Mac stays awake, the display may go dark")
        XCTAssertEqual(folder.read("Requests/" + request), "\(getpid())\n", "and the helper is asked for the closed lid")
        XCTAssertFalse(pulse.isRunning)

        choose(items()[1])
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"],
                       "«Не гасить экран» on the fly: the display is held too")
        XCTAssertTrue(pulse.isRunning, "and the screen saver is kept away")
        XCTAssertEqual(beats, 1)

        choose(items()[1])
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep"], "and off again, while the system stays held")
        XCTAssertFalse(pulse.isRunning)

        choose(items()[2])
        XCTAssertFalse(folder.exists("Requests/" + request), "«Не засыпать с закрытой крышкой» off: the request goes")
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep"])
        choose(items()[2])
        XCTAssertTrue(folder.exists("Requests/" + request))

        choose(items()[0])
        XCTAssertFalse(awake.isOn)
        XCTAssertEqual(pmsetAssertions(), [], "«Выключить»: nothing is left")
        XCTAssertFalse(folder.exists("Requests/" + request))
    }

    func testQuittingTheAppReleasesEverything() {
        let folder = TemporaryFolder()
        let requests = folder.folder("Requests")
        let blocker = SystemSleepBlocker(requests: requests, keepsScreenSaverAway: false)
        let awake = Awake(blocker: blocker, store: StandInStore(), power: { PowerState(percent: 80, onBattery: false) },
                          options: { Awake.Options(keepsDisplayOn: true) }, schedulesTicks: false)
        awake.start(.unlimited)
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"])
        awake.shutdown(forget: false)
        XCTAssertEqual(pmsetAssertions(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: requests), [], "the helper lets go at once")
    }

    func testWithoutTheHelperTheModeHoldsAllTheSame() {
        let folder = TemporaryFolder()
        let blocker = SystemSleepBlocker(requests: folder.sub("no helper"), keepsScreenSaverAway: false)
        XCTAssertTrue(blocker.hold(display: false, closedLid: true))
        XCTAssertEqual(pmsetAssertions(), ["PreventUserIdleSystemSleep"])
        blocker.release()
        XCTAssertEqual(pmsetAssertions(), [])
    }

    // MARK: The screen saver

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testThePulseDeclaresTheUserActiveOnlyWhileADisplayIsAwake() {
        var displayIsAwake = true
        var beats = 0
        let pulse = UserActivityPulse(every: 0.1, displayIsAwake: { displayIsAwake }, declare: { _ in beats += 1 })
        pulse.start()
        XCTAssertEqual(beats, 1, "at once")
        pulse.start()
        XCTAssertEqual(beats, 1, "one pulse at a time")
        spin(0.45)
        XCTAssertGreaterThanOrEqual(beats, 3, "then every interval")
        // The user put the display to sleep, or closed the lid: it stays dark.
        displayIsAwake = false
        let asleep = beats
        spin(0.35)
        XCTAssertEqual(beats, asleep)
        displayIsAwake = true
        pulse.stop()
        spin(0.35)
        XCTAssertEqual(beats, asleep, "nothing after stop")
        XCTAssertFalse(pulse.isRunning)
    }

    func testThePulseBeatsAboutEveryFiftySeconds() {
        XCTAssertEqual(UserActivityPulse.interval, 50)
    }
}
