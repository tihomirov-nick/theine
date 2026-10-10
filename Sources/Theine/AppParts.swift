import AppKit
import SwiftUI
import TheineCore

// The places where an app made from the template becomes itself. The rest of Sources/Theine is the family's
// plumbing: the icon with its menu and panel, Settings, updates, the interface language and the sounds.
// Theine is a menu bar utility that keeps the Mac from falling asleep. Its interface is the menu of the icon, which
// opens at any click; the mode itself (the timer, the power assertion, the saved session) is `Awake` in TheineCore.

// MARK: - 1. The glyph

extension MenuBarIcon {
    /// The cup in the menu bar: empty while the Mac may sleep, full while Theine keeps it awake. The drawing is the
    /// family's glyph file (Glyph.swift, Theine.swift) and sets its own size (20 pt wide, 15 pt tall) and lines, so the
    /// template's `box` is not used.
    static func drawGlyph(in ctx: CGContext, box: CGRect, awake: Bool) {
        ctx.saveGState()
        Glyph.enterMenuBox(ctx, bounds: Theine.bounds, scale: max(1, abs(ctx.ctm.a)))
        Theine.draw(ctx, awake: awake, line: Glyph.menuLine, gap: Glyph.menuGap)
        ctx.restoreGState()
    }
}

// MARK: - 2. The main view

/// Theine has no main view: the menu of the icon is its interface. The panel under the icon carries only the update
/// card, so this view stays empty.
struct MainView: View {
    var body: some View {
        EmptyView()
    }
}

// MARK: - 3. The app's section in Settings

/// What Settings keep, read every time they are needed: Settings change them while the mode runs.
enum Preferences {
    static let keepsDisplayKey = "keepDisplayOn"
    static let stopsOnLowBatteryKey = "stopOnLowBattery"
    static let startsOnLaunchKey = "startOnLaunch"
    static let shortcutKey = "toggleShortcut"

    static func options() -> Awake.Options {
        let defaults = UserDefaults.standard
        return Awake.Options(keepsDisplayOn: defaults.object(forKey: keepsDisplayKey) as? Bool ?? false,
                             stopsOnLowBattery: defaults.object(forKey: stopsOnLowBatteryKey) as? Bool ?? true)
    }

    /// «Не гасить экран», the flag in the menu of the icon.
    static func setKeepsDisplay(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: keepsDisplayKey)
    }

    static var startsOnLaunch: Bool {
        UserDefaults.standard.object(forKey: startsOnLaunchKey) as? Bool ?? false
    }

    /// The global shortcut that turns the mode on and off. None until the user records one: ⇧⌘T would take
    /// «Открыть закрытую вкладку» away from every browser.
    static var shortcut: Shortcut? {
        Shortcut.load(shortcutKey, default: nil)
    }
}

/// The card of Theine's own settings, under «Основные» and «Обновления».
struct AppSettingsSection: View {
    @AppStorage(Preferences.stopsOnLowBatteryKey) private var stopsOnLowBattery = true
    @AppStorage(Preferences.startsOnLaunchKey) private var startsOnLaunch = false

    var body: some View {
        Group {
            SectionTitle("Theine")
            VStack(spacing: 0) {
                SwitchRow(title: L("Выключать при заряде ниже 20%"),
                          help: L("Когда Mac работает от батареи и заряд падает ниже 20%, Theine выключается сам. При таком заряде он не включится, пока Mac не поставят на зарядку"),
                          isOn: $stopsOnLowBattery)
                Separator()
                SwitchRow(title: L("Включать при запуске"),
                          help: L("При запуске Theine сразу включается, без ограничения по времени. Режим, который шёл до перезапуска, возвращается и без этой настройки"),
                          isOn: $startsOnLaunch)
                Separator()
                Row(title: L("Сочетание для включения"),
                    help: L("Включает и выключает Theine в любом приложении. По умолчанию сочетания нет: ⇧⌘T в меню работает, только пока меню открыто")) {
                    ShortcutRecorder(key: Preferences.shortcutKey)
                }
            }
            .card()
        }
    }
}

// MARK: - 4. The actions of the menu and 5. being busy

@MainActor
enum AppActions {
    /// The mode, with the power assertion, the battery and the preferences of this Mac behind it.
    static let awake = Awake(options: Preferences.options)

    /// Set by `TheineApplication` when the user quits from a menu: the mode ends for good, while a restart that the app
    /// makes for itself (an update, a new language) keeps it.
    private static var quitsForGood = false
    private static var observers: [NSObjectProtocol] = []

    /// The app's actions at the top of the menu of the icon, above «Настройки…»; the menu adds the separator.
    /// «Включить» or «Выключить», the flag «Не гасить экран», «Включить на» with the time to choose from, then a line with
    /// the state. ⇧⌘T on the first one is a label: it works while the menu is open. A shortcut for any app is the user's
    /// own (Settings, `applyShortcut`). The flag is the one preference that lives here and not in Settings: with it the mode
    /// holds the display too, without it the display goes dark as usual; a click changes what is held at once.
    static func menuItems(awake: Awake? = nil, setKeepsDisplay: @escaping (Bool) -> Void = Preferences.setKeepsDisplay) -> [NSMenuItem] {
        let awake = awake ?? AppActions.awake
        var items: [NSMenuItem] = []
        // A new version is waiting: the dot on the icon leads here, and the card with «Обновить» opens in the panel.
        if case .available(let release) = Updater.shared.state {
            items.append(ClosureMenuItem(L("Доступна версия %@", release.version)) { StatusItem.shared.showPanel() })
            items.append(.separator())
        }
        let toggle = ClosureMenuItem(awake.isOn ? L("Выключить") : L("Включить"), keyEquivalent: "t") { awake.toggle() }
        toggle.keyEquivalentModifierMask = [.command, .shift]
        items.append(toggle)

        let display = ClosureMenuItem(L("Не гасить экран"), checked: awake.keepsDisplayOn) {
            setKeepsDisplay(!awake.keepsDisplayOn)
            awake.optionsChanged()
        }
        display.toolTip = L("Пока Theine включён, экран не гаснет от бездействия. Без флажка он гаснет как обычно, а Mac продолжает работать")
        items.append(display)

        let lengths = NSMenuItem(title: L("Включить на"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, length) in presets() {
            submenu.addItem(ClosureMenuItem(title) { awake.start(length) })
        }
        lengths.submenu = submenu
        items.append(lengths)

        items.append(.separator())
        let status = NSMenuItem(title: awake.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)
        return items
    }

    private static func presets() -> [(title: String, length: AwakeLength)] {
        [(L("Без ограничения"), .unlimited), (L("5 минут"), .minutes(5)), (L("15 минут"), .minutes(15)),
         (L("30 минут"), .minutes(30)), (L("1 час"), .hours(1)), (L("2 часа"), .hours(2)), (L("4 часа"), .hours(4)),
         (L("8 часов"), .hours(8))]
    }

    /// The app is in the middle of something a restart would break. Never: the mode is saved and comes back after a
    /// restart, so an update does not have to wait for it.
    static var isBusy: Bool {
        false
    }

    // MARK: Life of the mode

    /// At launch, once the icon is in place: the icon follows the mode, a timed session or a low battery ends it with a
    /// sound, the options and the wake from sleep are looked at, the user's shortcut works if there is one. Then the mode
    /// comes back: the saved session of a restart, or, if the setting says so, a new one without a limit.
    static func launch() {
        awake.onChange = { StatusItem.shared.isAwake = awake.isOn }
        awake.onFinish = { reason in SoundEffects.play(reason == .expired ? .success : .failure) }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { awake.optionsChanged() }
        })
        // A Mac that slept anyway (the lid, the user) may have passed the end of the session meanwhile.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                           queue: .main) { _ in
            MainActor.assumeIsolated { awake.tick() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { applyShortcut() }
        })
        applyShortcut()
        if !awake.restore(), Preferences.startsOnLaunch {
            awake.start(.unlimited)
        }
    }

    /// Registers the user's shortcut, replacing the one before it; nothing when there is none, which is the default.
    static func applyShortcut() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        if let shortcut = Preferences.shortcut {
            center.register(shortcut) { MainActor.assumeIsolated { awake.toggle() } }
        }
    }

    static func noteQuitByUser() {
        quitsForGood = true
    }

    /// The app is quitting.
    static func quit() {
        awake.shutdown(forget: quitsForGood)
    }
}

/// The application object. A quit that comes from a menu item is the user's own: the mode ends. A quit that code asks
/// for, the restart for an update or for a new interface language, keeps the mode for the next launch.
final class TheineApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        if sender is NSMenuItem { AppActions.noteQuitByUser() }
        super.terminate(sender)
    }
}
