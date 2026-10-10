import AppKit
import SwiftUI
import TheineCore

/// The icon in the menu bar. Any click opens the menu, which is Theine's interface: the app's actions, then the family
/// standard «Настройки…», «Проверить обновления…», «О приложении», «Завершить». The panel under the icon carries only the
/// update (a new version, the answer to a check).
@MainActor
final class StatusItem: NSObject {
    static let shared = StatusItem()

    private var item: NSStatusItem?
    private lazy var panel = StatusPanel()

    /// The dot of a new version the user has not answered yet (see `Updates`).
    var showsBadge = false {
        didSet {
            guard showsBadge != oldValue else { return }
            refreshImage()
        }
    }

    /// The mode is on: the cup is full.
    var isAwake = false {
        didSet {
            guard isAwake != oldValue else { return }
            refreshImage()
        }
    }

    private func refreshImage() {
        item?.button?.image = MenuBarIcon.image(badge: showsBadge, awake: isAwake)
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image(badge: showsBadge, awake: isAwake)
        item.button?.toolTip = "Theine"
        item.button?.setAccessibilityLabel("Theine")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
    }

    @objc private func clicked() {
        showMenu()
    }

    /// The panel under the icon, for the update: from «Проверить обновления…» and from the new version in the menu.
    func showPanel() {
        guard let button = item?.button, let window = button.window else { return }
        panel.show(under: window.convertToScreen(button.convert(button.bounds, to: nil)))
    }

    /// The menu under the icon, whatever the click; also at a launch by hand and when the app is opened again.
    func showMenu() {
        panel.dismiss()
        guard let item else { return }
        // The menu belongs to the item only while it is open, so it is built anew at every click.
        item.menu = Self.menu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The menu of the icon: the app's actions (`AppActions.menuItems`), then the part every app of the family shares.
    /// Its actions go to the app delegate.
    static func menu(actions: [NSMenuItem]? = nil) -> NSMenu {
        let menu = NSMenu()
        let actions = actions ?? AppActions.menuItems()
        actions.forEach(menu.addItem)
        if !actions.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: L("Настройки…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(withTitle: L("Проверить обновления…"), action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("О приложении «Theine»"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Завершить Theine"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}

/// The app's main window: a black panel right under the menu bar icon, the family's dark style with no arrow. It takes
/// the keyboard without bringing the app forward, so fields in it work and the app in front stays in front. It closes
/// on a click elsewhere, on Esc, on a second click on the icon and when the menu or Settings open. Its size follows the
/// content, the top stays under the icon.
@MainActor
final class StatusPanel: NSPanel, NSWindowDelegate {
    /// The icon's frame on screen, to stay under it while the content changes size.
    private var anchor: NSRect = .zero
    private var keyMonitor: Any?
    /// When the panel last closed because it lost the keyboard.
    private var resignedAt = Date.distantPast

    /// The panel closed a moment ago because another window took the keyboard: the click on the icon that caused it
    /// should not open it again.
    var closedByThisClick: Bool { Date().timeIntervalSince(resignedAt) < 0.3 }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: PanelView())
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(under anchor: NSRect) {
        self.anchor = anchor
        // The size of the content before the first placing: SwiftUI would otherwise resize the panel after it shows.
        if let view = contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0, size.height > 0 { setContentSize(size) }
        }
        place()
        makeKeyAndOrderFront(nil)
        // Esc closes the panel, a field in it included.
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.isKeyWindow else { return event }
            self.dismiss()
            return nil
        }
        // The shadow follows the drawn corners once SwiftUI has drawn them.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Updates.panelClosed()
    }

    /// Centered under the icon, inside the screen, 6 pt below the menu bar.
    private func place() {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        var x = anchor.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: min(anchor.minY, visible.maxY) - 6))
    }

    func windowDidResize(_ notification: Notification) {
        guard anchor != .zero else { return }
        place()
        invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        resignedAt = Date()
        dismiss()
    }
}

/// What the panel shows: the update when there is something to say about it, and the app's main view.
struct PanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            UpdateCard()
            MainView()
        }
        .padding(Metrics.inset)
        .frame(width: 300)
        .background(Color.black, in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
        .tint(Brand.color)
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
    }
}
