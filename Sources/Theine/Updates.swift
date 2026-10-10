import AppKit
import Combine
import SwiftUI
import TheineCore

extension Updater {
    /// Releases of the app on GitHub.
    static let shared = Updater(repo: "tihomirov-nick/theine")
}

// MARK: - Texts

/// The updater (Updater.swift) is the same file in every app of the family and has no texts: the app names its states.
extension Updater.Failure {
    /// One short line.
    var text: String {
        switch self {
        case .offline: return L("Нет связи с сервером обновлений")
        case .rateLimited: return L("Сервер обновлений просит подождать")
        case .noInstaller: return L("Установщика новой версии пока нет")
        case .download: return L("Скачивание прервалось")
        case .damaged: return L("Установщик повреждён")
        case .notTrusted: return L("Новая версия подписана иначе")
        case .cannotReplace: return L("Не получилось поставить новую версию")
        }
    }

    /// Why, and what to do: in the tooltip.
    var help: String {
        switch self {
        case .offline: return L("Проверьте интернет и попробуйте ещё раз")
        case .rateLimited: return L("Слишком много проверок подряд. Попробуйте через час")
        case .noInstaller: return L("Новая версия вышла, но её установщик ещё не выложен. Попробуйте позже")
        case .download: return L("Скачивание не закончилось. Попробуйте ещё раз или скачайте установщик со страницы загрузки")
        case .damaged: return L("Скачанный установщик повреждён или в нём нет новой версии Theine. Попробуйте ещё раз")
        case .notTrusted:
            return L("Новая версия подписана не так, как установленная, и сама не ставится. Скачайте установщик со страницы загрузки и перетащите Theine в папку «Программы»")
        case .cannotReplace:
            return L("Не получилось поставить новую версию. Откройте установщик и перетащите Theine в папку «Программы»")
        }
    }

    /// The release page or the downloaded installer helps more than another try.
    var needsHands: Bool { self == .notTrusted || self == .cannotReplace }
}

extension Updater {
    /// The status under the version in Settings.
    var statusText: String {
        switch state {
        case .idle:
            // An update that installs itself is under way.
            if let job = automaticUpdate {
                return job.ready ? L("Версия %@ скачана", job.release.version) : L("Скачиваю версию %@", job.release.version)
            }
            return isDevelopmentBuild ? L("Сборка для разработки") : ""
        case .checking: return L("Проверяю…")
        case .upToDate: return L("Последняя версия")
        case .available(let release): return L("Доступна версия %@", release.version)
        case .downloading(_, let progress): return L("Скачивание %@%%", "\(Int(progress * 100))")
        case .installing: return L("Обновляюсь…")
        case .failed(let failure, _): return failure.text
        }
    }

    var statusHelp: String {
        switch state {
        case .failed(let failure, _): return failure.help
        case .idle where automaticUpdate?.ready == true:
            return L("Новая версия встанет, когда Theine освободится или закроется")
        default:
            if isDevelopmentBuild { return L("Эта сборка сделана из исходного кода и сама не обновляется") }
            if !automaticChecks {
                return L("Автоматическая проверка выключена. Проверить можно этой кнопкой или пунктом «Проверить обновления…» в меню значка")
            }
            return automaticInstall ? L("Theine сам проверяет, вышла ли новая версия, и ставит её, когда ничем не занят")
                                    : L("Theine сам проверяет, вышла ли новая версия, и предлагает её поставить")
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

// MARK: - What the app does with the updater

/// Connects the updater to the app. A new version an automatic check offers (`freshOffer`, when installing by itself is
/// off or impossible) puts a dot on the menu bar icon, and the panel under the icon shows it with its buttons. What a
/// check from the menu finds shows in the panel too.
@MainActor
enum Updates {
    private static var subscriptions: Set<AnyCancellable> = []

    static func start() {
        let updater = Updater.shared
        // An update that installs itself, and the restart for a new interface language, wait while the app is busy.
        updater.appIsBusy = { AppActions.isBusy }
        updater.$state.receive(on: RunLoop.main).sink { state in
            StatusItem.shared.showsBadge = state.hasOffer
            if case .failed(_, .some) = state { SoundEffects.play(.failure) }
        }.store(in: &subscriptions)
        // The dot on the icon is where the offer is seen.
        updater.$freshOffer.receive(on: RunLoop.main).sink { release in
            if release != nil { updater.offerShown() }
        }.store(in: &subscriptions)
        updater.start()
    }

    /// «Проверить обновления…»: the panel opens and shows what the check finds.
    static func checkFromMenu() {
        Updater.shared.check(userInitiated: true)
        StatusItem.shared.showPanel()
    }

    /// The panel closed: an answer to a check (up to date, a failure without a release) has been seen.
    static func panelClosed() {
        switch Updater.shared.state {
        case .upToDate, .failed(_, nil): Updater.shared.dismiss()
        default: break
        }
    }
}

extension Updater.State {
    /// A release waits for the user's word: offered, or failed on the way. The menu bar icon wears a dot meanwhile.
    var hasOffer: Bool {
        switch self {
        case .available, .failed(_, .some): return true
        default: return false
        }
    }
}

/// The update in the panel under the menu bar icon: a check under way, its answer, a new version with «Позже» and
/// «Обновить», the download. Nothing while there is nothing to say.
struct UpdateCard: View {
    @ObservedObject var updater: Updater = .shared

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            line(L("Проверяю…"), symbol: "arrow.triangle.2.circlepath")
        case .upToDate:
            line(L("Установлена последняя версия"), symbol: "checkmark.circle.fill")
        case .available(let release):
            card(L("Доступна версия %@", release.version), symbol: "arrow.down.circle.fill", help: release.notes) {
                Button(L("Позже")) { updater.dismiss() }.appButton(.secondary)
                Button(L("Обновить")) { updater.install() }.appButton(.primary)
            }
        case .downloading(_, let progress):
            card(L("Скачивание %@%%", "\(Int(progress * 100))"), symbol: "arrow.down.circle.fill") {
                Button(L("Остановить")) { updater.cancel() }.appButton(.secondary)
            }
        case .installing(let release):
            line(L("Обновляюсь до версии %@…", release.version), symbol: "arrow.down.circle.fill")
        case .failed(let failure, nil):
            line(failure.text, symbol: "exclamationmark.triangle.fill", help: failure.help)
        case .failed(let failure, .some):
            card(failure.text, symbol: "exclamationmark.triangle.fill", help: failure.help) {
                Button(L("Позже")) { updater.dismiss() }.appButton(.secondary)
                if failure.needsHands {
                    Button(L("Скачать")) { updater.openReleasePage() }.appButton(.primary)
                } else {
                    Button(L("Попробовать снова")) { updater.install() }.appButton(.primary)
                }
            }
        }
    }

    private func line(_ text: String, symbol: String, help: String = "") -> some View {
        Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.secondary)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
        .card()
        .help(help)
    }

    private func card<Buttons: View>(_ text: String, symbol: String, help: String = "",
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(text).lineLimit(2)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Palette.secondary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .help(help)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
