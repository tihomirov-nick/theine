import Foundation

/// SleepDisabled, the system setting `pmset -a disablesleep` changes: while it is on the Mac does not sleep at all, lid
/// closed or not. pmset does the work; tests put a stand-in here.
public protocol SleepSetting {
    /// The setting now; nil when it cannot be read.
    func read() -> Bool?
    /// Changes the setting; false when that did not work.
    func write(_ disabled: Bool) -> Bool
}

/// SleepDisabled through pmset: `pmset -g` lists it among the system-wide settings, `pmset -a disablesleep 1` or `0`
/// changes it (root only).
public struct PMSet: SleepSetting {
    public var path: String
    public var runner: CommandRunning

    public init(path: String = "/usr/bin/pmset", runner: CommandRunning = ProcessRunner()) {
        self.path = path
        self.runner = runner
    }

    public func read() -> Bool? {
        guard let result = runner.run(path, ["-g"], timeout: 10), result.status == 0 else { return nil }
        return Self.sleepDisabled(in: result.output)
    }

    public func write(_ disabled: Bool) -> Bool {
        runner.run(path, ["-a", "disablesleep", disabled ? "1" : "0"], timeout: 10)?.status == 0
    }

    /// The line "SleepDisabled 1" of `pmset -g`. Without the line the setting is at its default, off.
    static func sleepDisabled(in output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let words = line.split { $0 == " " || $0 == "\t" }
            if words.count >= 2, words[0] == "SleepDisabled" { return words[1] == "1" }
        }
        return false
    }
}

/// One run of the helper. launchd starts it at load, whenever the folder of requests changes and every few seconds
/// (`Helper.interval`). It looks whether a live Theine asks (`HelperRequest.live`) and makes SleepDisabled follow:
/// - asked, nothing held yet: it writes down the value it finds, then turns SleepDisabled on, unless it is on already;
/// - asked and held: if someone has switched SleepDisabled off meanwhile, it turns it on again and from then on keeps 0
///   as the value to put back, since 0 is what that someone wants;
/// - nobody asks, something held: it puts 0 back if 0 is what it found, then forgets. A 1 that was there before Theine
///   (Amphetamine's, for one) stays as it is;
/// - nobody asks, nothing held: nothing, and pmset is not even run.
/// The value from before lives in a file only root may write (`Helper.saved`). It outlives the helper, restarts of the
/// Mac and updates of the helper, so the first run after any of them settles whatever was left: a run at load with no
/// live request gives the setting back. The value is written down before the setting changes and forgotten only after
/// it is back, so a run cut short anywhere leaves the next one the right picture.
public struct HelperPass {
    public enum Outcome: Equatable {
        /// Nobody asks and nothing is held.
        case idle
        /// A Theine has asked: SleepDisabled is on; `before` is what it was.
        case held(before: Bool)
        /// Still asked, still on.
        case holding
        /// Still asked, but someone had switched SleepDisabled off: it is on again, and 0 is what goes back later.
        case retaken
        /// Nobody asks any more and the value from before is back. `restored` is false when there was nothing to put
        /// back: SleepDisabled was on before Theine, or someone has switched it off already.
        case released(restored: Bool)
        /// SleepDisabled could not be read or changed, or the value from before could not be written down. The rest
        /// stays as it was, and the next run tries again.
        case failed(String)
    }

    let requests: String
    let saved: String
    let setting: SleepSetting
    let processes: ProcessTable

    public init(requests: String = Helper.requests, saved: String = Helper.saved, setting: SleepSetting = PMSet(),
                processes: ProcessTable = SystemProcesses()) {
        self.requests = requests
        self.saved = saved
        self.setting = setting
        self.processes = processes
    }

    public func run() -> Outcome {
        let asked = !HelperRequest.live(in: requests, processes: processes).isEmpty
        let before = savedValue()
        if !asked, before == nil { return .idle }
        guard let now = setting.read() else { return .failed("SleepDisabled cannot be read") }
        switch (asked, before) {
        case (true, nil):
            guard save(now) else { return .failed("the value from before cannot be written down") }
            if !now, !setting.write(true) { return .failed("SleepDisabled cannot be turned on") }
            return .held(before: now)
        case (true, .some):
            if now { return .holding }
            guard save(false) else { return .failed("the value from before cannot be written down") }
            guard setting.write(true) else { return .failed("SleepDisabled cannot be turned on") }
            return .retaken
        case (false, .some(let value)):
            let restores = !value && now
            if restores, !setting.write(false) { return .failed("SleepDisabled cannot be turned off") }
            unlink(saved)
            return .released(restored: restores)
        case (false, nil):
            return .idle
        }
    }

    /// The value from before; nil when nothing is held. Anything but "1" in the file counts as 0, so that a damaged
    /// file lets the Mac sleep again rather than keep it awake for good.
    private func savedValue() -> Bool? {
        guard let data = FileManager.default.contents(atPath: saved) else {
            return FileManager.default.fileExists(atPath: saved) ? false : nil
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func save(_ value: Bool) -> Bool {
        (try? Data((value ? "1\n" : "0\n").utf8).write(to: URL(fileURLWithPath: saved), options: .atomic)) != nil
    }
}
