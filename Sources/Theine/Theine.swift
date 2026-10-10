// Theine (keeps the Mac awake), after the user's two samples: a solid cup with a ring handle, seen from the side and a
// little from above, so the oval of its opening shows inside the rim.
//  - awake (the menu bar's "on" and the app icon), the full cup: a thin dark ring just inside the rim, and within it the
//    drink, a solid oval;
//  - asleep (the menu bar's "off"): the same cup, empty: a dark oval inside the rim and no drink.
// `gap`: Glyph.iconGap or Glyph.menuGap. Box conventions: Glyph.swift.
import CoreGraphics

enum Theine {
    /// The ink of the cup in the box, both states: the menu bar and the app icon fit it to their room (Glyph.swift).
    static let bounds = CGRect(x: 5.8, y: 14, width: 93.4, height: 72)

    /// The rim, the outline of the cup's opening: an oval as wide as the cup's body.
    static let rim = CGRect(x: 5.8, y: 14, width: 78.4, height: 46)
    static let bottom: CGFloat = 86
    /// The handle is a ring, its hole `handleHole` wide and high, at the right of the body.
    static let handleCenter = Glyph.p(86.3, 59.5)
    static let handleHole = CGSize(width: 10, height: 13)

    /// The bowl under the rim, closed along the rim's middle: two quarters of an ellipse.
    static func body() -> CGPath {
        let p = Glyph.p, k: CGFloat = 0.5523
        let depth = bottom - rim.midY
        let path = CGMutablePath()
        path.move(to: p(rim.minX, rim.midY))
        path.addCurve(to: p(rim.midX, bottom), control1: p(rim.minX, rim.midY + k * depth),
                      control2: p(rim.midX - k * rim.width / 2, bottom))
        path.addCurve(to: p(rim.maxX, rim.midY), control1: p(rim.midX + k * rim.width / 2, bottom),
                      control2: p(rim.maxX, rim.midY + k * depth))
        path.closeSubpath()
        return path
    }

    /// The handle's ring, along the middle of its line `t`.
    static func handle(line t: CGFloat) -> CGPath {
        let rx = handleHole.width / 2 + t / 2, ry = handleHole.height / 2 + t / 2
        return CGPath(ellipseIn: CGRect(x: handleCenter.x - rx, y: handleCenter.y - ry, width: 2 * rx, height: 2 * ry),
                      transform: nil)
    }

    static func draw(_ ctx: CGContext, awake: Bool, line w: CGFloat, gap: CGFloat) {
        Glyph.fill(ctx, body().union(CGPath(ellipseIn: rim, transform: nil)))
        Glyph.stroke(ctx, handle(line: 0.95 * w), 0.95 * w)
        // The rim keeps a band of white a little thinner than the handle's line; inside it the opening is dark.
        let opening = rim.insetBy(dx: 0.85 * w, dy: 0.85 * w)
        Glyph.cut(ctx) { Glyph.fill(ctx, CGPath(ellipseIn: opening, transform: nil)) }
        // The full cup: the drink is a white oval, parted from the rim by a ring of the family's gap. It sits a little
        // low, as the drink does when the cup is seen from above: the ring is thicker at the far side.
        if awake {
            let drink = opening.insetBy(dx: gap, dy: gap).offsetBy(dx: 0, dy: 0.3 * gap)
            Glyph.fill(ctx, CGPath(ellipseIn: drink, transform: nil))
        }
    }
}
