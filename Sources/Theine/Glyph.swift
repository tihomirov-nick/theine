// Shared conventions for the marks of the five new menu bar utilities: Theine, One Thing, Tomato, Provoda, Coal.
// CoreGraphics only, so a make_icon.swift script can compile these files on their own.
//
// Every mark is drawn by one function in a 100 × 100 box, y growing down from the top left corner, with the context's
// current fill and stroke colour. Cut-outs use the .clear blend mode, so draw into a transparent layer. Each mark also
// states `bounds`, the rectangle its ink covers in the box (all its states and frames together). Both sizes scale the
// mark until its ink takes all the room there is, and the lines and gaps, which are counted in box units, grow with it,
// so the weight of a mark stays the same against its size:
//  - app icon: the ink's longer side is `iconFill` (80%) of the tile, centred, clear of the tile's rounded corners. The
//    tile is the body of the flat drawing (the 1024 square whose body is the squircle at 100...924, as in
//    Subline/scripts/make_icon.swift). `enterIconMark` sets this up for the Icon Composer layer, where the body is the
//    whole tile; lines `Glyph.iconLine` = 7.2 units.
//  - menu bar: the ink is `menuMarkHeight` = 20 pt tall, centred on a canvas `menuCanvasHeight` = 22 pt tall (the 24 pt
//    menu bar's own height is the frame of its items) and as wide as the mark's proportions ask, a margin on each side
//    (`menuCanvas`); the status item is `variableLength`. Lines `Glyph.menuLine` = 8.23 units. `enterMenuBox` sets this up.
import CoreGraphics

enum Glyph {
    static let iconLine: CGFloat = 7.2
    static let menuLine: CGFloat = 8.23
    /// The black gaps that part a solid mark into pieces (Tomato's calyx, Coal's faces, Theine's ring round the drink),
    /// in box units.
    static let iconGap: CGFloat = 3.4
    static let menuGap: CGFloat = 4.2

    /// The menu bar image, in points: the height of the ink, the height of the canvas and the room left on each side.
    static let menuMarkHeight: CGFloat = 20
    static let menuCanvasHeight: CGFloat = 22
    static let menuMargin: CGFloat = 1
    /// How much of the tile's side the ink's longer side takes on the app icon; `iconBody` is the tile in the flat drawing.
    static let iconFill: CGFloat = 0.8
    static let iconBody: CGFloat = 824

    /// Points per box unit in the menu bar for a mark whose ink is `bounds`.
    static func menuScale(for bounds: CGRect) -> CGFloat { menuMarkHeight / bounds.height }

    /// The menu bar canvas of a mark: 22 pt tall, as wide as the ink plus the margin on each side, in whole points.
    static func menuCanvas(for bounds: CGRect) -> CGSize {
        CGSize(width: (bounds.width * menuScale(for: bounds) + 2 * menuMargin).rounded(.up), height: menuCanvasHeight)
    }

    /// Box units to points on the menu bar canvas, y down: the ink is centred, its left edge on a whole pixel of a screen
    /// of `scale` pixels per point, as FaceID's mark does.
    static func menuPlacement(bounds: CGRect, scale: CGFloat) -> CGAffineTransform {
        let s = menuScale(for: bounds), canvas = menuCanvas(for: bounds)
        let left = ((canvas.width - bounds.width * s) / 2 * scale).rounded() / scale
        let top = (canvas.height - menuMarkHeight) / 2
        return CGAffineTransform(translationX: left - bounds.minX * s, y: top - bounds.minY * s).scaledBy(x: s, y: s)
    }

    /// Pixels (of the flat drawing) per box unit on the app icon.
    static func iconScale(for bounds: CGRect) -> CGFloat { iconFill * iconBody / max(bounds.width, bounds.height) }

    /// `ctx` draws in the flat drawing, y up, with the body at 100...924. Afterwards it draws in box units, y down, the
    /// ink centred on the body.
    static func enterIconBody(_ ctx: CGContext, bounds: CGRect) {
        let k = iconScale(for: bounds)
        ctx.translateBy(x: 512 - bounds.midX * k, y: 512 + bounds.midY * k)
        ctx.scaleBy(x: k, y: -k)
        prepare(ctx)
    }

    /// `ctx` is a 1024 × 1024 Icon Composer layer (y up). Afterwards it draws in box units, y down: the flat drawing's
    /// body (100...924) is scaled to the whole layer, as make_icon.swift does, and the ink sits in its middle.
    static func enterIconMark(_ ctx: CGContext, bounds: CGRect) {
        ctx.scaleBy(x: 1024 / iconBody, y: 1024 / iconBody)
        ctx.translateBy(x: -100, y: -100)
        enterIconBody(ctx, bounds: bounds)
    }

    /// `ctx` draws in menu bar points with y down on the mark's canvas at `scale` pixels per point. Afterwards it draws
    /// in box units.
    static func enterMenuBox(_ ctx: CGContext, bounds: CGRect, scale: CGFloat) {
        ctx.concatenate(menuPlacement(bounds: bounds, scale: scale))
        prepare(ctx)
    }

    static func prepare(_ ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Runs `body` with the clear blend mode: whatever it fills or strokes is cut out of the layer.
    static func cut(_ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        body()
        ctx.restoreGState()
    }

    static func stroke(_ ctx: CGContext, _ path: CGPath, _ width: CGFloat) {
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
    }

    static func fill(_ ctx: CGContext, _ path: CGPath) {
        ctx.addPath(path)
        ctx.fillPath()
    }

    static func line(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        return path
    }

    static func disc(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
               transform: nil)
    }

    static func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A smooth closed curve through `points` (Catmull-Rom).
    static func smoothClosed(_ points: [CGPoint], tension t: CGFloat = 1 / 6) -> CGPath {
        let path = CGMutablePath(), n = points.count
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            path.addCurve(to: p2, control1: p(p1.x + (p2.x - p0.x) * t, p1.y + (p2.y - p0.y) * t),
                          control2: p(p2.x - (p3.x - p1.x) * t, p2.y - (p3.y - p1.y) * t))
        }
        path.closeSubpath()
        return path
    }
}
