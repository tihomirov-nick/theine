import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// The real blocker: an IOKit power assertion. By default `PreventUserIdleSystemSleep`, the Mac stays awake while the
/// display may go dark; with `display` it is `PreventUserIdleDisplaySleep`, the display stays on too. The system drops
/// the assertion when the process ends, whatever the way.
private let noAssertion = IOPMAssertionID(0)

@MainActor
public final class PowerAssertion: SleepBlocker {
    private var id = noAssertion
    private var holdsDisplay = false

    public init() {}

    public func hold(display: Bool) -> Bool {
        if id != noAssertion, holdsDisplay == display { return true }
        let type: String = display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var created = noAssertion
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 L("Theine не даёт Mac заснуть") as CFString, &created)
        guard result == kIOReturnSuccess else { return false }
        // The new assertion already holds when the old one goes, so the Mac is never free to sleep in between.
        release()
        id = created
        holdsDisplay = display
        return true
    }

    public func release() {
        if id != noAssertion { IOPMAssertionRelease(id) }
        id = noAssertion
        holdsDisplay = false
    }

    deinit {
        if id != noAssertion { IOPMAssertionRelease(id) }
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
