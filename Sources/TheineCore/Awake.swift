import Foundation

/// How long the Mac is kept awake.
public enum AwakeLength: Equatable, Sendable {
    case unlimited
    case limited(TimeInterval)

    public static func minutes(_ count: Int) -> AwakeLength { .limited(TimeInterval(count) * 60) }
    public static func hours(_ count: Int) -> AwakeLength { .limited(TimeInterval(count) * 3600) }
}

/// The mode while it is on, as it is saved for the restart of the app (an update, a new interface language).
public struct AwakeSession: Equatable, Codable, Sendable {
    public var started: Date
    /// When the time runs out; nil when the mode lasts until it is turned off.
    public var ends: Date?
    /// The boot of the Mac it began in: the mode does not outlive a restart of the Mac.
    public var boot: TimeInterval?

    public init(started: Date, ends: Date?, boot: TimeInterval? = nil) {
        self.started = started
        self.ends = ends
        self.boot = boot
    }
}

/// Why the mode turned itself off.
public enum AwakeStop: Equatable, Sendable {
    /// The time ran out.
    case expired
    /// The Mac runs on battery and the charge fell below `Awake.lowBatteryPercent`.
    case lowBattery
}

/// Holds the Mac awake: the real one is `PowerAssertion`, previews and tests use `StandInBlocker`.
@MainActor
public protocol SleepBlocker: AnyObject {
    /// Keeps the Mac from idle sleep, and the display too when `display` is set; replaces what was held before. False
    /// when the system refuses.
    func hold(display: Bool) -> Bool
    func release()
}

/// Where the session is kept between launches.
@MainActor
public protocol SessionStore: AnyObject {
    func load() -> AwakeSession?
    func save(_ session: AwakeSession?)
}

/// The mode «не давать Mac засыпать»: one session at a time, with or without a time limit. It holds the power assertion
/// while the session lasts, saves the session at every change so that a restart picks it up (`restore`), and turns
/// itself off when the time runs out or, if the option is on, when the battery runs low. Everything it takes from the
/// world (the assertion, the store, the clock, the battery, the options) is passed in, so the tests drive it with a
/// clock of their own.
@MainActor
public final class Awake {
    public struct Options: Equatable, Sendable {
        /// «Не гасить экран»: the display stays on too, not only the system.
        public var keepsDisplayOn: Bool
        /// «Выключать при заряде ниже 20%».
        public var stopsOnLowBattery: Bool

        public init(keepsDisplayOn: Bool = false, stopsOnLowBattery: Bool = true) {
            self.keepsDisplayOn = keepsDisplayOn
            self.stopsOnLowBattery = stopsOnLowBattery
        }
    }

    /// On battery, below this charge (in percent) the mode turns off and does not turn on.
    public static let lowBatteryPercent = 20
    /// How often a running session looks at the clock and the battery.
    public static let pollInterval: TimeInterval = 30

    public private(set) var session: AwakeSession?
    /// Why the mode turned itself off last; cleared when it is turned on or off by hand.
    public private(set) var lastStop: AwakeStop?
    /// The mode turned on or off.
    public var onChange: (() -> Void)?
    /// The mode turned itself off, or refused to turn on, for this reason.
    public var onFinish: ((AwakeStop) -> Void)?

    private let blocker: SleepBlocker
    private let store: SessionStore
    private let power: () -> PowerState
    private let options: () -> Options
    private let now: () -> Date
    private let boot: () -> TimeInterval
    private let schedulesTicks: Bool
    private var timer: Timer?
    private var heldDisplay = false

    /// Without a `blocker` and a `store` the real ones are used: the power assertion and the app's preferences.
    public init(blocker: SleepBlocker? = nil, store: SessionStore? = nil,
                power: @escaping () -> PowerState = PowerSource.current, options: @escaping () -> Options = { Options() },
                now: @escaping () -> Date = { Date() }, boot: @escaping () -> TimeInterval = SystemBoot.time,
                schedulesTicks: Bool = true) {
        self.blocker = blocker ?? PowerAssertion()
        self.store = store ?? DefaultsSessionStore()
        self.power = power
        self.options = options
        self.now = now
        self.boot = boot
        self.schedulesTicks = schedulesTicks
    }

    public var isOn: Bool { session != nil }

    /// «Не гасить экран» as the options give it now: while the mode is on, the display stays on too.
    public var keepsDisplayOn: Bool { options().keepsDisplayOn }

    /// The battery alone forbids the mode right now: the option is on, the Mac runs on battery and the charge is low.
    public var isBlockedByBattery: Bool {
        guard options().stopsOnLowBattery else { return false }
        let state = power()
        return state.onBattery && (state.percent ?? 100) < Self.lowBatteryPercent
    }

    // MARK: Turning on and off

    /// Starts a session of `length` from now, or replaces the running one. False when the battery or the system says no.
    @discardableResult
    public func start(_ length: AwakeLength) -> Bool {
        if isBlockedByBattery {
            if isOn { end(because: .lowBattery) } else { refuse() }
            return false
        }
        let began = now()
        var ends: Date?
        if case .limited(let seconds) = length { ends = began.addingTimeInterval(seconds) }
        guard hold() else { return false }
        session = AwakeSession(started: began, ends: ends, boot: boot())
        lastStop = nil
        store.save(session)
        schedule()
        onChange?()
        return true
    }

    /// Turns the mode off by hand.
    public func stop() {
        if isOn { end(because: nil) }
    }

    public func toggle() {
        if isOn { stop() } else { start(.unlimited) }
    }

    /// Picks up the saved session after a restart of the app, if it still holds: its time has not run out, it began in
    /// this boot of the Mac and the battery allows it. Otherwise it is forgotten.
    @discardableResult
    public func restore() -> Bool {
        guard !isOn, let saved = store.load() else { return false }
        let expired = saved.ends.map { $0 <= now() } ?? false
        let otherBoot = saved.boot.map { $0 != boot() } ?? false
        if expired || otherBoot || isBlockedByBattery {
            store.save(nil)
            return false
        }
        guard hold() else { return false }
        session = saved
        schedule()
        onChange?()
        return true
    }

    /// The app is quitting. The assertion goes with the process anyway; the saved session stays for the restart, unless
    /// the user quit the app, which ends the mode for good.
    public func shutdown(forget: Bool) {
        cancelTimer()
        blocker.release()
        heldDisplay = false
        if forget { store.save(nil) }
    }

    // MARK: Looking at the clock and the world

    /// Ends the session whose time is up or whose battery is low; otherwise plans the next look. Called by its own timer,
    /// after the Mac wakes up and when the options change.
    public func tick() {
        guard let session else { return }
        if let ends = session.ends, ends <= now() {
            end(because: .expired)
        } else if isBlockedByBattery {
            end(because: .lowBattery)
        } else {
            schedule()
        }
    }

    /// The options changed (the flag «Не гасить экран» in the menu, or Settings): the flag changes what is held at once,
    /// the battery option may end the session.
    public func optionsChanged() {
        guard isOn else { return }
        if options().keepsDisplayOn != heldDisplay { _ = hold() }
        if isBlockedByBattery { end(because: .lowBattery) }
    }

    // MARK: Words

    /// The line under the actions in the menu: «Включено 12 мин», «Осталось 40 мин», «Выключено».
    public var statusText: String {
        if let session {
            if let ends = session.ends { return L("Осталось %@", Self.span(ends.timeIntervalSince(now()), roundingUp: true)) }
            return L("Включено %@", Self.span(now().timeIntervalSince(session.started), roundingUp: false))
        }
        if isBlockedByBattery { return L("Выключено, заряд ниже 20%") }
        if lastStop == .expired { return L("Выключено, время вышло") }
        return L("Выключено")
    }

    /// «12 мин», «2 ч», «2 ч 5 мин»; the time left rounds up, the time spent rounds down.
    static func span(_ seconds: TimeInterval, roundingUp: Bool) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(roundingUp ? .up : .down)))
        if minutes == 0 { return L("меньше минуты") }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("%@ мин", "\(rest)") }
        if rest == 0 { return L("%@ ч", "\(hours)") }
        return L("%@ ч %@ мин", "\(hours)", "\(rest)")
    }

    // MARK: Inside

    /// Holds what the options ask for; false when the system refuses.
    private func hold() -> Bool {
        let display = options().keepsDisplayOn
        guard blocker.hold(display: display) else { return false }
        heldDisplay = display
        return true
    }

    private func end(because reason: AwakeStop?) {
        session = nil
        lastStop = reason
        blocker.release()
        heldDisplay = false
        store.save(nil)
        cancelTimer()
        onChange?()
        if let reason { onFinish?(reason) }
    }

    /// Turning on was refused for the battery: nothing changes, the user hears it.
    private func refuse() {
        lastStop = .lowBattery
        onFinish?(.lowBattery)
    }

    /// The next look: when the time runs out, or in `pollInterval` for the battery.
    private func schedule() {
        cancelTimer()
        guard schedulesTicks, let session else { return }
        var interval = Self.pollInterval
        if let ends = session.ends { interval = min(interval, max(ends.timeIntervalSince(now()), 0.5)) }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = min(interval * 0.1, 3)
        // Common modes: the timer also runs while the menu of the icon is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Stand-ins for previews and tests

/// A blocker that holds nothing, for previews and tests: it remembers what it was asked.
@MainActor
public final class StandInBlocker: SleepBlocker {
    /// Whether something is held now, and whether it includes the display.
    public private(set) var isHeld = false
    public private(set) var holdsDisplay = false
    /// Every `hold(display:)` in order.
    public private(set) var requests: [Bool] = []
    public private(set) var releases = 0
    /// The system says no.
    public var refuses = false

    public init() {}

    public func hold(display: Bool) -> Bool {
        requests.append(display)
        guard !refuses else { return false }
        isHeld = true
        holdsDisplay = display
        return true
    }

    public func release() {
        isHeld = false
        holdsDisplay = false
        releases += 1
    }
}

/// A store in memory, for previews and tests.
@MainActor
public final class StandInStore: SessionStore {
    public var session: AwakeSession?

    public init(_ session: AwakeSession? = nil) {
        self.session = session
    }

    public func load() -> AwakeSession? { session }
    public func save(_ session: AwakeSession?) { self.session = session }
}
