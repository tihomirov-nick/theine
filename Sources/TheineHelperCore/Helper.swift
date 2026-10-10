import Foundation

/// What Theine and its helper agree on. The helper is a small program that runs as root: `TheineHelper`, installed once
/// with the administrator's password into /Library/PrivilegedHelperTools and started by launchd. It does one thing: keeps
/// the system setting SleepDisabled on (what `pmset -a disablesleep 1` sets) while a running Theine asks for it, so that
/// the Mac stays awake with its lid closed too, on battery and on power. It takes no commands and no paths from anyone:
/// everything it runs or reads lies where only root can write, except the requests, which it checks (`HelperRequest`).
/// What it does with them is in HelperPass.swift.
public enum Helper {
    /// Raised whenever the helper or its launchd job changes. Theine installs the helper again, which asks for the
    /// password once more, only when the installed one reports another number.
    public static let version = 1

    public static let label = "com.theine.app.helper"
    /// The installed helper and its launchd job, in folders only root may write to.
    public static let executable = "/Library/PrivilegedHelperTools/com.theine.app.helper"
    public static let launchDaemon = "/Library/LaunchDaemons/com.theine.app.helper.plist"
    /// Root's folder for Theine: the requests, and the value of SleepDisabled from before the helper changed it.
    public static let folder = "/Library/Application Support/Theine"
    /// Anyone may add a file here (the folder is sticky, like /tmp), so the helper believes a request only when the PID in
    /// it is a live Theine of the file's owner.
    public static let requests = folder + "/Requests"
    /// "0" or "1": SleepDisabled as the helper found it before turning it on. The file exists only while the helper
    /// holds the setting.
    public static let saved = folder + "/SleepDisabledBefore"
    /// launchd starts the helper this often (seconds), besides at load and whenever `requests` changes: a Theine that
    /// ends without a word (a crash, a forced quit) loses its hold within this time.
    public static let interval = 5
    /// The helper inside Theine.app, until it is installed.
    public static let bundledPath = "Contents/Helpers/TheineHelper"

    /// The launchd job: the installed helper and nothing else, at load, at every change of `requests` and every
    /// `interval` seconds. It belongs to Theine in the Login Items of System Settings.
    public static func launchDaemonPlist() -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "StartInterval": interval,
            "WatchPaths": [requests],
            // launchd spaces the runs of a job 10 seconds apart unless told otherwise.
            "ThrottleInterval": 1,
            "AssociatedBundleIdentifiers": ["com.theine.app"],
        ]
        // A dictionary of plain values always serializes.
        return try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// The executable of a Theine app, wherever the app is: …/Theine.app/Contents/MacOS/Theine.
    public static func isTheine(executable path: String) -> Bool {
        path.hasSuffix("/Theine.app/Contents/MacOS/Theine")
    }
}
