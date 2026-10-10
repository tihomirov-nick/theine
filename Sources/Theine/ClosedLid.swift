import AppKit
import os
import TheineCore
import TheineHelperCore

/// «Не засыпать с закрытой крышкой» as the user meets it. The helper behind it (Helper.swift) needs the administrator's
/// password once. Theine asks for it when the mode turns on with the option on and no helper of this version in place:
/// first one line about why, then the system's password dialog. A refusal or a failure leaves the rest of the mode
/// working and puts a note with «Разрешить…» into the menu and Settings. Theine does not ask again by itself until the
/// option is turned on anew. A helper of a newer version goes in the same way, with the password once more.
@MainActor
final class ClosedLid: ObservableObject {
    static let shared = ClosedLid(world: .system)
    /// The user said no to the password, or the install failed.
    static let declinedKey = "closedLidHelperDeclined"

    /// What the decisions depend on. The app uses `system`; tests give stand-ins and run everything at once.
    @MainActor
    struct World {
        /// The helper of this version is in place.
        var helperIsInstalled: @MainActor () -> Bool
        var modeIsOn: @MainActor () -> Bool
        var optionIsOn: @MainActor () -> Bool
        /// The line before the password dialog; true for «Продолжить».
        var confirm: @MainActor () -> Bool
        /// The password dialog and the install, off the main thread; the outcome comes back on it.
        var install: @MainActor (@escaping @MainActor (HelperInstaller.Outcome) -> Void) -> Void
        /// The running mode asks the new helper.
        var holdAgain: @MainActor () -> Void
        /// Where the refusal is kept between launches.
        var loadDeclined: @MainActor () -> Bool
        var saveDeclined: @MainActor (Bool) -> Void
        /// Runs a block on the main thread a little later, once the menu that started it has closed.
        var later: @MainActor (@escaping @MainActor () -> Void) -> Void

        static var system: World {
            let installed = InstalledHelper()
            return World(helperIsInstalled: { installed.check() }, modeIsOn: { AppActions.awake.isOn },
                         optionIsOn: { Preferences.keepsAwakeWithLidClosed }, confirm: ClosedLid.confirm,
                         install: ClosedLid.install, holdAgain: { AppActions.awake.holdAgain() },
                         loadDeclined: { UserDefaults.standard.bool(forKey: declinedKey) },
                         saveDeclined: { UserDefaults.standard.set($0, forKey: declinedKey) },
                         later: { block in DispatchQueue.main.async { MainActor.assumeIsolated(block) } })
        }
    }

    /// The helper of this version is in place.
    @Published private(set) var isInstalled = false
    /// The line before the password dialog, or the dialog itself, is open.
    @Published private(set) var isAsking = false
    @Published private(set) var declined: Bool

    private let world: World
    private static let logger = Logger(subsystem: "com.theine.app", category: "helper")

    init(world: World) {
        self.world = world
        declined = world.loadDeclined()
    }

    /// The note in the menu and in Settings: the option is on, the helper is missing and the user has said no.
    var showsNote: Bool {
        world.optionIsOn() && !isInstalled && declined
    }

    /// Looks whether the helper is in place.
    func refresh() {
        let installed = world.helperIsInstalled()
        if installed != isInstalled { isInstalled = installed }
    }

    /// The mode has turned on: by the user, at launch, or back after a restart.
    func modeTurnedOn() {
        askIfNeeded()
    }

    /// The option has been turned on, in the menu or in Settings: an earlier «Не сейчас» no longer stands.
    func optionTurnedOn() {
        setDeclined(false)
        askIfNeeded()
    }

    /// «Разрешить…»: straight to the password dialog, the click itself says what it is for.
    func allow() {
        ask(explaining: false)
    }

    private func askIfNeeded() {
        refresh()
        guard world.modeIsOn(), world.optionIsOn(), !isInstalled, !declined else { return }
        ask(explaining: true)
    }

    /// The line about why (`explaining`), then the password dialog; one at a time.
    private func ask(explaining: Bool) {
        guard !isAsking else { return }
        isAsking = true
        world.later { [self] in
            if explaining, !world.confirm() {
                finish(.cancelled)
                return
            }
            world.install { [self] outcome in finish(outcome) }
        }
    }

    private func finish(_ outcome: HelperInstaller.Outcome) {
        isAsking = false
        refresh()
        switch outcome {
        case .installed where isInstalled:
            setDeclined(false)
            world.holdAgain()
        case .cancelled:
            setDeclined(true)
        case .installed:
            Self.logger.error("The helper went in but does not report version \(Helper.version, privacy: .public)")
            setDeclined(true)
            SoundEffects.play(.failure)
        case .failed(let reason):
            Self.logger.error("The helper did not go in: \(reason, privacy: .public)")
            setDeclined(true)
            SoundEffects.play(.failure)
        }
    }

    private func setDeclined(_ value: Bool) {
        guard value != declined else { return }
        declined = value
        world.saveDeclined(value)
    }

    // MARK: The real world

    private static func confirm() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Чтобы Mac не засыпал с закрытой крышкой, macOS один раз спросит пароль администратора")
        alert.addButton(withTitle: L("Продолжить"))
        alert.addButton(withTitle: L("Не сейчас"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func install(_ done: @escaping @MainActor (HelperInstaller.Outcome) -> Void) {
        guard let installer = HelperInstaller.forThisApp() else {
            done(.failed("this copy of Theine is not signed with a certificate, so its helper cannot be checked"))
            return
        }
        let prompt = L("Theine ставит помощника, чтобы Mac не засыпал с закрытой крышкой.")
        Task.detached(priority: .userInitiated) {
            let outcome = installer.install(prompt: prompt)
            await done(outcome)
        }
    }
}

/// Whether the installed helper is of this version. Cheap to ask often: the helper is run for its version only when its
/// file has changed since the last look.
@MainActor
private final class InstalledHelper {
    /// The helper's file as last seen (inode, change time, size; nil: no file) and the version it reported then.
    private var seen: (file: [Int]?, version: Int?)?

    func check() -> Bool {
        let file = Self.identity(Helper.executable)
        if seen == nil || file != seen?.file {
            seen = (file, file == nil ? nil : HelperInstaller.installedVersion())
        }
        return seen?.version == Helper.version && FileManager.default.fileExists(atPath: Helper.launchDaemon)
            && FileManager.default.fileExists(atPath: Helper.requests)
    }

    private static func identity(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [Int(info.st_ino), info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec, Int(info.st_size)]
    }
}
