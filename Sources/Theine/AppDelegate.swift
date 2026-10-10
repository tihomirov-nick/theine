import AppKit
import TheineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started at login (or brought back quietly by an update): the icon appears and nothing opens.
    private var startedQuietly = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The family's dark look everywhere: the panel, Settings, menus and the About panel.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        startedQuietly = Updater.LoginItem.launchedAtLogin
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        StatusItem.shared.install()
        Updates.start()
        // The mode comes back first (after a restart for an update or a language, or at launch if the setting says so),
        // so that whatever opens below shows it.
        AppActions.launch()
        if SettingsWindow.reopensAfterRestart() {
            // Back from the restart for a new interface language.
            SettingsWindow.show()
        } else if !startedQuietly {
            // Opened by hand: the menu shows where the app lives, once the icon has its place in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { StatusItem.shared.showMenu() }
        }
    }

    /// Opening the app again (from Finder, Spotlight, Launchpad) while it runs opens the menu, once the request is answered.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { StatusItem.shared.showMenu() }
        return true
    }

    /// The power assertion goes; the mode stays saved for the restart unless the user quit the app.
    func applicationWillTerminate(_ notification: Notification) {
        AppActions.quit()
    }

    // MARK: Actions of the menus (the menu of the icon and the invisible main menu)

    @objc func showSettings(_ sender: Any?) {
        SettingsWindow.show()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updates.checkFromMenu()
    }

    /// The standard About panel: the name, the version and the copyright from Info.plist.
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
