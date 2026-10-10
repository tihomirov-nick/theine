import AppKit

/// The menu bar icon: the app's glyph as a template image, so macOS tints it for the menu bar and its selection. The
/// canvas is 22 pt high, as much as the 24 pt menu bar leaves, with the glyph 20 pt tall in the middle, and as wide as
/// the glyph's proportions ask (Glyph.swift); the status item is `variableLength`, as wide as the image plus the menu
/// bar's own margins. The glyph itself is the app's: `drawGlyph` in AppParts.swift.
enum MenuBarIcon {
    static let canvas = NSSize(width: Glyph.menuCanvas(for: Theine.bounds).width, height: Glyph.menuCanvasHeight)
    /// The glyph's ink in the canvas.
    static let box = CGRect(x: (canvas.width - Theine.bounds.width * Glyph.menuScale(for: Theine.bounds)) / 2,
                            y: (Glyph.menuCanvasHeight - Glyph.menuMarkHeight) / 2,
                            width: Theine.bounds.width * Glyph.menuScale(for: Theine.bounds), height: Glyph.menuMarkHeight)
    /// The thickest line of the glyph in points: Glyph.menuLine in box units, grown with the glyph.
    static let lineWidth = Glyph.menuLine * Glyph.menuScale(for: Theine.bounds)
    /// The dot of a new version waiting for the user, in the top right corner, and the gap round it.
    static let badge = CGRect(x: canvas.width - 6.5, y: 0.5, width: 6, height: 6)
    static let badgeGap: CGFloat = 1.6

    /// The icon; `badge` adds the dot of an update the user has not answered yet, `awake` draws the full cup of the mode
    /// that is on (the drink in it) instead of the empty cup at rest.
    static func image(badge: Bool = false, awake: Bool = false) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(.black)
            ctx.setFillColor(.black)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            drawGlyph(in: ctx, box: box, awake: awake)
            if badge {
                // A gap round the dot, so it stays apart from the glyph under it.
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: Self.badge.insetBy(dx: -badgeGap, dy: -badgeGap))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: Self.badge)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Theine"
        return image
    }
}
