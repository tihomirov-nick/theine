import AppKit
import SwiftUI
import TheineCore

/// The settings window (one instance), black from the title bar down, in the order of the family standard: «Основные»,
/// «Обновления», then the app's own section (`AppSettingsSection`).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    /// Set right before the restart for a new interface language: Settings open again after it.
    private static let reopenKey = "reopenSettingsAfterRestart"

    static func show() {
        if window == nil {
            let window = makeWindow()
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window, not shown yet; the preview renderer draws it too.
    static func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Настройки Theine")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        // Shown over a full-screen app too, in the Space the user is in.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    /// «Перезапустить»: the app quits the usual way and opens again with Settings.
    static func restartForLanguage() {
        UserDefaults.standard.set(true, forKey: reopenKey)
        InterfaceLanguage.relaunch()
        // Still running: the quit was refused, or there is no app bundle to open again.
        UserDefaults.standard.removeObject(forKey: reopenKey)
    }

    /// Whether this launch is the restart for a new interface language; asked once.
    static func reopensAfterRestart() -> Bool {
        let reopen = UserDefaults.standard.bool(forKey: reopenKey)
        if reopen { UserDefaults.standard.removeObject(forKey: reopenKey) }
        return reopen
    }
}

struct SettingsView: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(SoundEffects.enabledKey) private var soundEffects = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            SectionTitle(L("Основные"))
            VStack(spacing: 0) {
                LanguageRows()
                Separator()
                LoginItemRows()
                Separator()
                SwitchRow(title: L("Звуковые эффекты"),
                          help: L("Theine коротко звучит, когда что-то закончилось или не получилось. Громкость та же, что у звуков предупреждений. Если в Системных настройках, в разделе «Звук», выключены звуковые эффекты интерфейса, звуков нет"),
                          isOn: $soundEffects)
            }
            .card()

            SectionTitle(L("Обновления"))
            VStack(spacing: 0) {
                SwitchRow(title: L("Проверять обновления"),
                          help: L("Theine смотрит, нет ли новой версии, при запуске, раз в три часа и после пробуждения Mac"),
                          isOn: Binding(get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                Separator()
                SwitchRow(title: L("Обновлять автоматически"),
                          help: L("Новая версия скачивается и ставится сама, когда Theine ничем не занят. Если выключить, Theine будет только предлагать обновиться"),
                          isOn: Binding(get: { updater.automaticInstall }, set: { updater.automaticInstall = $0 }))
                    .disabled(!updater.automaticChecks)
                Separator()
                VersionRow(updater: updater)
            }
            .card()

            AppSettingsSection()
        }
        .padding(Metrics.inset)
        .frame(width: 380)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(Brand.color)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

extension InterfaceLanguage {
    /// Languages are named in their own language, so anyone finds theirs.
    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

/// The interface language: «Как в системе», «Русский» or «English», kept as the app's own `AppleLanguages` (see
/// InterfaceLanguage.swift). Read again when Settings open and when the app comes back to the front, since System
/// Settings writes the same setting. A language other than this launch's offers a restart.
private struct LanguageRows: View {
    @ObservedObject private var updater = Updater.shared
    @State private var choice = InterfaceLanguage.saved()
    @State private var needsRestart = false

    var body: some View {
        Row(title: L("Язык интерфейса"),
            help: L("При варианте «Как в системе» Theine берёт первый подходящий язык из списка в Системных настройках, раздел «Язык и регион». Новый язык включится после перезапуска")) {
            MenuCapsule(title: choice.title, help: L("Язык интерфейса"), makeMenu: menu)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if needsRestart {
            Separator()
            NoteRow(text: L("Язык сменится после перезапуска")) {
                Button(L("Перезапустить")) { SettingsWindow.restartForLanguage() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(updater.appIsBusy())
            }
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for option in InterfaceLanguage.allCases {
            menu.addItem(ClosureMenuItem(option.title, checked: option == choice) {
                InterfaceLanguage.save(option)
                refresh()
            })
            if option == .system { menu.addItem(.separator()) }
        }
        return menu
    }

    private func refresh() {
        choice = InterfaceLanguage.saved()
        needsRestart = InterfaceLanguage.needsRestart(running: Localization.current)
    }
}

/// Opening at login (`Updater.LoginItem`), and the way to System Settings when it is switched off there: only the user
/// can switch it on again in Login Items.
private struct LoginItemRows: View {
    @ObservedObject private var loginItem = Updater.LoginItem.shared
    @State private var needsApproval = false

    var body: some View {
        SwitchRow(title: L("Запускать при входе"),
                  help: L("При входе в систему Theine запускается в строке меню, чтобы вовремя ставить обновления"),
                  isOn: Binding(get: { loginItem.isEnabled }, set: {
                      loginItem.set($0)
                      needsApproval = loginItem.needsApproval
                  }))
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if needsApproval {
            Separator()
            NoteRow(text: L("Выключено в Системных настройках"),
                    help: L("Запуск при входе выключен в Системных настройках, в разделе «Объекты входа». Включить его снова можно только там")) {
                Button(L("Открыть «Объекты входа»")) { loginItem.openSystemSettings() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    /// System Settings may have changed it meanwhile.
    private func refresh() {
        loginItem.refresh()
        needsApproval = loginItem.needsApproval
    }
}

/// The version with the update status under it, and «Проверить сейчас»; «Обновить» when a check has found a version.
private struct VersionRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Версия %@", updater.currentVersion))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !updater.statusText.isEmpty {
                    Text(updater.statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Group {
                if case .available = updater.state {
                    Button(L("Обновить")) { updater.install() }
                        .appButton(.primary)
                } else {
                    Button(L("Проверить сейчас")) { updater.check(userInitiated: true) }
                        .appButton(.secondary)
                        .disabled(updater.isBusy)
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .help(updater.statusHelp)
    }
}
