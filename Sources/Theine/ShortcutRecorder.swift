import AppKit
import Carbon.HIToolbox
import SwiftUI
import TheineCore

extension Notification.Name {
    /// The global shortcut was changed in Settings (or recording one started or ended).
    static let shortcutsChanged = Notification.Name("TheineShortcutsChanged")
}

/// A button that records the next key combination as the global shortcut, from Screenshooter's ShortcutRecorder in the
/// family's dark style: «Не задано» until the user records one, «Нажмите сочетание…» while it listens, Esc cancels and ⌫
/// removes. The shortcut is kept in the preferences under `key`; `AppActions.applyShortcut` registers it.
struct ShortcutRecorder: View {
    let key: String

    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? L("Нажмите сочетание…") : (shortcut?.display ?? L("Не задано")))
                    .opacity(shortcut == nil && !recording ? 0.55 : 1)
                    .frame(minWidth: 96)
            }
            .appButton(recording ? .primary : .secondary)
            .controlSize(.small)
            .help(L("Нажмите и введите сочетание с ⌘, ⌃ или ⌥. Esc отменяет запись, ⌫ удаляет сочетание"))

            if shortcut != nil, !recording {
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary)
                }
                .buttonStyle(PressStyle())
                .help(L("Удалить сочетание"))
                .accessibilityLabel(L("Удалить сочетание"))
            }
        }
        .fixedSize()
        .onAppear { shortcut = Shortcut.load(key, default: nil) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        // Free the current combination, so pressing it records it instead of turning Theine on or off.
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                set(nil)
                stop()
            default:
                if let new = Shortcut(event: event) {
                    set(new)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    private func set(_ value: Shortcut?) {
        shortcut = value
        Shortcut.save(value, for: key)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}
