import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import TheineHelperCore

private let noAssertion = IOPMAssertionID(0)

/// The names of Theine's assertions, as `pmset -g assertions` shows them. Plain English whatever the interface language:
/// pmset prints a name with other letters as an empty one.
private enum AssertionName {
    static let system = "Theine keeps the Mac awake"
    static let display = "Theine keeps the display on"
    static let userActivity = "Theine keeps the screen saver away"
}

/// The real blocker. It holds the power assertions of `PowerAssertion`; with the display it also keeps the screen saver
/// away (`UserActivityPulse`); with the closed lid it asks the helper to keep SleepDisabled on (`ClosedLidRequest`).
/// While it holds anything, App Nap leaves Theine alone, so its timers come on time. The system drops the assertions
/// when the process ends, whatever the way, and the helper notices the end of the process within seconds.
@MainActor
public final class SystemSleepBlocker: SleepBlocker {
    private let assertions: PowerAssertion
    private let lid: ClosedLidRequest?
    private let pulse: UserActivityPulse?
    private var activity: NSObjectProtocol?

    /// The requests go to `requests`, nowhere without it. The screen saver is kept away by `pulse`, the real one unless
    /// `keepsScreenSaverAway` is off. Tests give a folder and a pulse of their own.
    public init(requests: String? = Helper.requests, keepsScreenSaverAway: Bool = true, pulse: UserActivityPulse? = nil) {
        assertions = PowerAssertion()
        lid = requests.map { ClosedLidRequest(folder: $0) }
        self.pulse = pulse ?? (keepsScreenSaverAway ? UserActivityPulse() : nil)
    }

    public func hold(display: Bool, closedLid: Bool) -> Bool {
        guard assertions.hold(display: display) else { return false }
        if display { pulse?.start() } else { pulse?.stop() }
        // Without the helper there is no folder for requests, and the rest holds anyway.
        if closedLid { lid?.hold() } else { lid?.release() }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Theine keeps the Mac awake")
        }
        return true
    }

    public func release() {
        assertions.release()
        pulse?.stop()
        lid?.release()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// The IOKit power assertions. `PreventUserIdleSystemSleep` keeps the Mac from sleeping when nobody touches it, and with
/// `display` `PreventUserIdleDisplaySleep` keeps the display from dimming and going dark as well. Each type is held at
/// most once: changing the display flag adds or drops the display's assertion while the system's stays, so the Mac is
/// never free to sleep in between. Neither stops a closed lid or Sleep in the Apple menu: that is the helper's part.
@MainActor
public final class PowerAssertion {
    private var system = noAssertion
    private var display = noAssertion

    public init() {}

    /// False when the system refuses; then nothing held before is lost, and nothing new stays held.
    public func hold(display keepsDisplay: Bool) -> Bool {
        var created = noAssertion
        if system == noAssertion {
            guard let id = Self.create(kIOPMAssertionTypePreventUserIdleSystemSleep, AssertionName.system) else {
                return false
            }
            system = id
            created = id
        }
        if keepsDisplay, display == noAssertion {
            guard let id = Self.create(kIOPMAssertionTypePreventUserIdleDisplaySleep, AssertionName.display) else {
                if created != noAssertion {
                    IOPMAssertionRelease(created)
                    system = noAssertion
                }
                return false
            }
            display = id
        } else if !keepsDisplay, display != noAssertion {
            IOPMAssertionRelease(display)
            display = noAssertion
        }
        return true
    }

    public func release() {
        if system != noAssertion { IOPMAssertionRelease(system) }
        if display != noAssertion { IOPMAssertionRelease(display) }
        system = noAssertion
        display = noAssertion
    }

    private static func create(_ type: String, _ name: String) -> IOPMAssertionID? {
        var id = noAssertion
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    deinit {
        if system != noAssertion { IOPMAssertionRelease(system) }
        if display != noAssertion { IOPMAssertionRelease(display) }
    }
}

/// «Не гасить экран» keeps the screen saver away too. The screen saver counts the time since the user last did
/// something, and a display assertion does not reliably stop that clock, so every `interval` seconds the system hears
/// that the user is active (`IOPMAssertionDeclareUserActivity`), the way video players do it. Only while a display is awake: a
/// display the user has put to sleep, or the one under a closed lid, stays dark.
@MainActor
public final class UserActivityPulse {
    public nonisolated static let interval: TimeInterval = 50

    private let every: TimeInterval
    private let displayIsAwake: () -> Bool
    private let declare: (inout IOPMAssertionID) -> Void
    private var timer: Timer?
    private var id = noAssertion

    /// The tests give a clock of their own and stand-ins for the display and the system.
    public init(every: TimeInterval = UserActivityPulse.interval,
                displayIsAwake: @escaping () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) == 0 },
                declare: ((inout IOPMAssertionID) -> Void)? = nil) {
        self.every = every
        self.displayIsAwake = displayIsAwake
        self.declare = declare ?? { id in
            _ = IOPMAssertionDeclareUserActivity(AssertionName.userActivity as CFString, kIOPMUserActiveLocal, &id)
        }
    }

    public var isRunning: Bool { timer != nil }

    /// Declares the user active now and then every `every` seconds, until `stop`.
    public func start() {
        guard timer == nil else { return }
        beat()
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.tolerance = 5
        // Common modes: the beat goes on while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if id != noAssertion { IOPMAssertionRelease(id) }
        id = noAssertion
    }

    private func beat() {
        // The same assertion is renewed every time: the system hands out another number only when the old one ran out.
        if displayIsAwake() { declare(&id) }
    }

    deinit {
        timer?.invalidate()
        if id != noAssertion { IOPMAssertionRelease(id) }
    }
}

/// Theine's side of the helper: the request that keeps the Mac awake with its lid closed (`HelperRequest`), written while
/// the mode with «Не засыпать с закрытой крышкой» runs and removed when it ends. Without the helper there is no folder for
/// it, and holding does nothing.
@MainActor
public final class ClosedLidRequest {
    private let folder: String
    private let uid: uid_t
    private let pid: pid_t

    public init(folder: String = Helper.requests, uid: uid_t = getuid(), pid: pid_t = getpid()) {
        self.folder = folder
        self.uid = uid
        self.pid = pid
    }

    /// False when there is no helper to ask, or its folder refuses the file.
    @discardableResult
    public func hold() -> Bool {
        HelperRequest.write(pid: pid, uid: uid, in: folder)
    }

    public func release() {
        HelperRequest.remove(uid: uid, in: folder)
    }
}

/// Where the Mac gets its power from.
public struct PowerState: Equatable, Sendable {
    /// The charge of the internal battery in percent; nil when the Mac has none.
    public var percent: Int?
    /// The Mac runs on its battery, not on the charger.
    public var onBattery: Bool

    public init(percent: Int?, onBattery: Bool) {
        self.percent = percent
        self.onBattery = onBattery
    }
}

public enum PowerSource {
    public static func current() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState(percent: nil, onBattery: false)
        }
        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let charge = description[kIOPSCurrentCapacityKey] as? Int,
                  let full = description[kIOPSMaxCapacityKey] as? Int, full > 0 else { continue }
            percent = Int((Double(charge) / Double(full) * 100).rounded(.down))
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return PowerState(percent: percent, onBattery: providing == kIOPSBatteryPowerValue)
    }
}

public enum SystemBoot {
    /// When the Mac was started, in seconds since 1970: the same number until the next restart of the Mac.
    public static func time() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boot.tv_sec)
    }
}

/// The session in the app's preferences, as JSON under one key.
@MainActor
public final class DefaultsSessionStore: SessionStore {
    public static let key = "awakeSession"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AwakeSession? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AwakeSession.self, from: $0) }
    }

    public func save(_ session: AwakeSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
