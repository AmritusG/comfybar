import AppKit

/// The menu-bar glyph: the ComfyBar mark (Core/Mark.swift), drawn from its vector paths at draw time
/// so it is crisp at every backing scale.
///
/// The C carries the status colour; the B follows the
/// menu bar like a template glyph.
///   not running - grey C (secondaryLabelColor)
///   idle        - green C
///   running     - blue C: a dim track, and the done fraction along the C at full colour
///                 (a quarter of the C when progress is not visible)
///   queued      - orange C, progress as for running
///   error       - red C
///
/// Why not isTemplate: Apple - "Images you mark as template images should consist of only
/// black and clear colors" (NSImage.isTemplate), so one image cannot be both coloured and
/// template. Instead the B is stroked with NSColor.labelColor inside the image's drawing
/// handler: dynamic colours resolve against the current drawing appearance ("the
/// appearance that the system uses for color and asset resolution", NSAppearance
/// .currentDrawing) - which, for the status-item button, is the menu bar's appearance.
enum IconRenderer {
    static func color(_ s: IconState) -> NSColor {
        switch s {
        case .notRunning: return .secondaryLabelColor
        case .idle: return .systemGreen
        case .running: return .systemBlue
        case .queued: return .systemOrange
        case .error: return .systemRed
        }
    }

    /// Length of the C along its centre line (the arc's sweep x radius), for the progress dash.
    static let cLength: CGFloat = PathMetrics.length(Mark.c)

    static func image(_ state: IconState, progress: Double?, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / Mark.viewBox
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // C - the status colour
            let c = color(state)
            ctx.setLineWidth(Mark.cStroke)
            switch state {
            case .running, .queued:
                ctx.addPath(Mark.c)
                ctx.setStrokeColor(c.withAlphaComponent(0.35).cgColor)
                ctx.strokePath()
                let frac = progress.map { max(0.04, min(1, $0)) } ?? 0.25
                ctx.addPath(Mark.c)
                ctx.setLineDash(phase: 0, lengths: [cLength * CGFloat(frac), cLength * 2])
                ctx.setStrokeColor(c.cgColor)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            default:
                ctx.addPath(Mark.c)
                ctx.setStrokeColor(c.cgColor)
                ctx.strokePath()
            }

            // B - follows the menu bar (resolved at draw time)
            ctx.setLineWidth(Mark.bStroke)
            ctx.addPath(Mark.b)
            ctx.setStrokeColor(NSColor.labelColor.cgColor)
            ctx.strokePath()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "ComfyUI: \(state.title)"
        return img
    }
}
