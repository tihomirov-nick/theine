import AppKit
import SwiftUI
import TheineCore

/// `--render-previews <folder>`: the menus of the icon in three states (at rest, on without a limit, on for a time), the
/// icon in both states and Settings drawn into one picture, <folder>/preview.png. The menus are the app's own items over
/// stand-ins of the power assertion, drawn by `MenuPreview` the way macOS draws a dark menu, since an NSMenu cannot be
/// drawn without showing it; the rest goes through hosting views in windows that are never shown. Nothing starts: no
/// status item, no updater, no login item, no power assertion.
@MainActor
enum PreviewRenderer {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// The menu of the icon as it opens when the mode has run for `minutes` (nil: it is off).
    private static func menu(running minutes: Int?, for length: AwakeLength = .unlimited) -> NSMenu {
        let clock = Clock()
        let awake = Awake(blocker: StandInBlocker(), store: StandInStore(), power: { PowerState(percent: 76, onBattery: false) },
                          options: { Awake.Options() }, now: { clock.now }, boot: { 1 }, schedulesTicks: false)
        if let minutes {
            awake.start(length)
            clock.now.addTimeInterval(TimeInterval(minutes) * 60)
        }
        return StatusItem.menu(actions: AppActions.menuItems(awake: awake))
    }

    static func run(into folder: URL) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resting = menu(running: nil), endless = menu(running: 12), timed = menu(running: 20, for: .minutes(60))
        guard let settings = snapshot(SettingsWindow.makeWindow()),
              let restingImage = snapshot(MenuPreview(items: resting.items)),
              let endlessImage = snapshot(MenuPreview(items: endless.items, highlightsSubmenu: true)),
              let timedImage = snapshot(MenuPreview(items: timed.items)),
              let lengthsImage = snapshot(MenuPreview(items: endless.items.first { $0.submenu != nil }?.submenu?.items ?? []))
        else {
            print("failed to draw the views")
            return
        }
        let margin: CGFloat = 24, bar: CGFloat = 24, below: CGFloat = 4, zoom: CGFloat = 4, gap: CGFloat = 28
        let menuWidth = max(restingImage.size.width, endlessImage.size.width, timedImage.size.width)
        let menuHeight = max(restingImage.size.height, endlessImage.size.height, timedImage.size.height)
        let firstWidth = menuWidth, secondWidth = menuWidth + 4 + lengthsImage.size.width
        let rowHeight = bar + below + menuHeight
        let width = margin + firstWidth + gap + secondWidth + margin + settings.size.width + margin
        let height = margin + max(rowHeight * 2 + gap, settings.size.height) + margin
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext
        NSColor(white: 0.34, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        /// A strip of menu bar with the icon at its real size, the menu hanging under it.
        func drop(_ menu: (image: CGImage, size: NSSize), awake: Bool, at x: CGFloat, top: CGFloat, lengths: Bool = false) {
            let strip = NSRect(x: x, y: top - bar, width: lengths ? secondWidth : firstWidth, height: bar)
            NSColor(white: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
            let iconRect = NSRect(x: strip.minX + 16, y: strip.midY - MenuBarIcon.canvas.height / 2,
                                  width: MenuBarIcon.canvas.width, height: MenuBarIcon.canvas.height)
            white(MenuBarIcon.image(awake: awake)).draw(in: iconRect)
            let rect = NSRect(x: strip.minX + 4, y: strip.minY - below - menu.size.height, width: menu.size.width, height: menu.size.height)
            cg.draw(menu.image, in: rect)
            if lengths {
                // The submenu opens beside the row «Включить на», its first item level with the row.
                let top = rect.maxY - 5 - 22 + 5
                cg.draw(lengthsImage.image, in: NSRect(x: rect.maxX + 4, y: top - lengthsImage.size.height,
                                                       width: lengthsImage.size.width, height: lengthsImage.size.height))
            }
        }
        let first = height - margin
        let second = first - rowHeight - gap
        let secondColumn = margin + firstWidth + gap
        drop(restingImage, awake: false, at: margin, top: first)
        drop(endlessImage, awake: true, at: secondColumn, top: first, lengths: true)
        drop(timedImage, awake: true, at: margin, top: second)

        // Both states of the icon, and the one with the dot of an update, four times larger.
        let large = NSSize(width: MenuBarIcon.canvas.width * zoom, height: MenuBarIcon.canvas.height * zoom)
        let captions = [("выкл", false, false), ("вкл", true, false), ("вкл, есть обновление", true, true)]
        var x = secondColumn + 12
        for (caption, awake, badge) in captions {
            let y = second - bar - below - large.height - 12
            white(MenuBarIcon.image(badge: badge, awake: awake)).draw(in: NSRect(origin: NSPoint(x: x, y: y), size: large))
            let text = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                        .foregroundColor: NSColor(white: 1, alpha: 0.6)])
            text.draw(at: NSPoint(x: x, y: y - 20))
            x += max(large.width, text.size().width) + 28
        }

        // Settings on the right.
        let settingsRect = NSRect(x: width - margin - settings.size.width, y: first - settings.size.height,
                                  width: settings.size.width, height: settings.size.height)
        cg.draw(settings.image, in: settingsRect)
        NSGraphicsContext.restoreGraphicsState()

        let url = folder.appendingPathComponent("preview.png")
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
            print("wrote \(url.path)")
        } else {
            print("failed to write \(url.path)")
        }
    }

    /// The view as drawn by a real hosting view, at its own size.
    private static func snapshot<V: View>(_ view: V) -> (image: CGImage, size: NSSize)? {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage.map { ($0, size) }
    }

    /// A window with its title bar, never ordered on screen.
    private static func snapshot(_ window: NSWindow) -> (image: CGImage, size: NSSize)? {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep.cgImage.map { ($0, frame.bounds.size) }
    }

    /// A template image in white, as the dark menu bar shows it.
    private static func white(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// A menu drawn the way macOS draws a dark one: the titles, the shortcuts on the right, the arrow of a submenu, the
/// separators, the dimmed lines that do nothing.
private struct MenuPreview: View {
    let items: [NSMenuItem]
    var highlightsSubmenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Color.white.opacity(0.14).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
                } else {
                    row(item)
                }
            }
        }
        .padding(.vertical, 5)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ item: NSMenuItem) -> some View {
        HStack(spacing: 28) {
            Text(item.title)
            Spacer(minLength: 0)
            if item.submenu != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            } else {
                Text(shortcut(item)).foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(item.isEnabled ? 1 : 0.4))
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(highlightsSubmenu && item.submenu != nil ? 0.16 : 0))
            .padding(.horizontal, 5))
    }

    private func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
            + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
    }
}
