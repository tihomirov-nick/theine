import AppKit
import SwiftUI
import TheineCore

// The family look, as in FaceID, Slovo and Subline: black surfaces with continuous corners, white text, cards in white
// 7 %, lines in white 8 %, and switches, capsules and buttons drawn by the app rather than by macOS, so they look the
// same on every macOS version.

/// The brand color: white with a cool tint, as in the black and white icons of the family.
enum Brand {
    static let color = Color(red: 0.96, green: 0.96, blue: 0.98)
    /// Text and symbols on the brand color.
    static let ink = Color.black
}

enum Palette {
    /// A card on the black window.
    static let card = Color.white.opacity(0.07)
    /// The line between the rows of a card.
    static let separator = Color.white.opacity(0.08)
    /// Capsules, tracks, fields.
    static let control = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.55)
}

enum Metrics {
    static let cardRadius: CGFloat = 14
    /// The black panel under the menu bar icon.
    static let panelRadius: CGFloat = 16
    /// Padding of the window and the panel.
    static let inset: CGFloat = 12
    /// Between the cards.
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 34
}

/// A tap on the trackpad, felt when a finger rests on it.
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Cards and rows

extension View {
    /// A card on the black window: white 7 % with continuous corners.
    func card(radius: CGFloat = Metrics.cardRadius) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The line between the rows of a card.
struct Separator: View {
    var leading: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

/// The name of a group of rows, above its card.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
}

/// One line of a card: the name on the left, the control on the right. What it does is in the tooltip.
struct Row<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

/// A quieter line under a row: a note on the left, a small button on the right.
struct NoteRow<Control: View>: View {
    let text: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

/// A highlight under a row that reacts to clicks anywhere in it.
private struct RowHover: View {
    let hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.05 : 0))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }
}

/// A row with a switch: a click anywhere in the row flips it.
struct SwitchRow: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Row(title: title, help: help) {
            Switch(isOn: $isOn)
        }
        // Unavailable (another switch turns it off): dimmed, and a click does nothing.
        .opacity(isEnabled ? 1 : 0.4)
        .background(RowHover(hovering: hovering && isEnabled))
        .onTapGesture {
            guard isEnabled else { return }
            isOn.toggle()
            Haptics.tap()
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // VoiceOver: one switch named after the row.
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .accessibilityHint(help ?? "")
        }
    }
}

// MARK: - Controls

/// Sinks when pressed, springs back with a little bounce.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                                   : .spring(response: 0.35, dampingFraction: 0.45),
                           value: configuration.isPressed)
        }
    }
}

/// A switch as on iPhone: the brand color with a black knob when on, the knob stretches while pressed and slides with
/// a spring.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.tap()
        } label: {
            EmptyView()
        }
        .buttonStyle(SwitchStyle(isOn: isOn))
        .accessibilityValue(isOn ? L("Вкл") : L("Выкл"))
    }

    private struct SwitchStyle: ButtonStyle {
        let isOn: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            Capsule()
                .fill(isOn ? Brand.color : Color.white.opacity(0.22))
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Brand.ink : .white)
                        .frame(width: pressed ? 22 : 17, height: 17)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .contentShape(Capsule())
                .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isOn)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: pressed)
        }
    }
}

/// A value chosen from a menu, as a capsule with a chevron: a click opens a native menu under it.
struct MenuCapsule: View {
    let title: String
    let help: String
    let makeMenu: () -> NSMenu
    @State private var hovering = false
    @State private var anchor = ViewAnchor()

    var body: some View {
        Button {
            anchor.popUp(makeMenu())
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.18 : 0.12)))
            .contentShape(Capsule())
            .background(AnchorView(anchor: anchor))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(title)
    }
}

/// Capsule buttons drawn by the app: the main action is filled with the brand color (the title black), the others are
/// translucent white. They sink when pressed, spring back with a little bounce and grow a bit under the pointer.
struct AppButtonStyle: ButtonStyle {
    enum Kind {
        /// The main action: a filled capsule in the brand color.
        case primary
        /// Everything else: a translucent capsule.
        case secondary
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(kind: kind, configuration: configuration)
    }
}

private struct AppButtonBody: View {
    let kind: AppButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Brand.ink : .white)
            .lineLimit(1)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 5 : 7)
            .background(Capsule().fill(background(pressed: pressed)))
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.92 : (hovering && !reduceMotion ? 1.03 : 1))
            .brightness(pressed && kind == .primary ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            // In quickly, back out with a little bounce, like iOS buttons.
            .animation(pressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.35, dampingFraction: 0.5),
                       value: pressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return Brand.color.opacity(pressed ? 0.75 : (hovering ? 0.92 : 1))
        case .secondary: return Color.white.opacity(pressed ? 0.24 : (hovering ? 0.2 : 0.14))
        }
    }
}

extension View {
    func appButton(_ kind: AppButtonStyle.Kind = .secondary) -> some View {
        buttonStyle(AppButtonStyle(kind: kind))
    }
}

// MARK: - Menus

/// Weak reference to an AppKit view placed behind a SwiftUI control, to open native menus under it: SwiftUI's Menu on
/// macOS draws a pop-up button of its own.
final class ViewAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let below = view.isFlipped ? view.bounds.maxY + 6 : view.bounds.minY - 6
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }
}

struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}
