import AppKit
import TheineCore

Localization.apply()

MainActor.assumeIsolated {
    // TheineApplication, to tell the user's own quit from the restart of an update (see AppParts.swift).
    let app = TheineApplication.shared
    let arguments = CommandLine.arguments
    // Draws the menus, Settings and the icon into one picture without showing anything on screen, then quits.
    if let i = arguments.firstIndex(of: "--render-previews"), i + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        PreviewRenderer.run(into: URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
