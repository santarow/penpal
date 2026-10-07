import AppKit

// Penpal's mark for the menu bar (#268, Jason: "lets change the icon to penpal icon"): the app icon's memo pad
// and nib (app/scripts/penpal-icon.swift, C) in one colour, a template image, so macOS tints it for light, dark
// and tinted menu bars. The same shapes and places as the icon, on its 1024 grid; drawn bolder, since at 18
// points the pad is an outline with its binding strip and one line of writing, and the nib a solid shape with a
// gap cut around it where it crosses the pad.
enum PenpalMark {
    static let menuBar: NSImage = image(size: 18)

    static func image(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx, in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    // The marks span x 179…857, y 225…854 of the 1024 grid (measured, strokes included); that box fills the rect.
    static func draw(_ ctx: CGContext, in rect: CGRect) {
        let box = CGRect(x: 176, y: 222, width: 684, height: 635)
        let s = min(rect.width / box.width, rect.height / box.height)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - box.midX * s, y: rect.midY - box.midY * s)
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(NSColor.black.cgColor); ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        func local(_ at: CGPoint, _ deg: CGFloat, _ k: CGFloat, _ body: () -> Void) {
            ctx.saveGState(); ctx.translateBy(x: at.x, y: at.y); ctx.rotate(by: deg * .pi / 180); ctx.scaleBy(x: k, y: k); body(); ctx.restoreGState()
        }
        // The pad: its outline, the binding strip across the top, a line of writing.
        local(CGPoint(x: 450, y: 540), -6, 1) {
            let w: CGFloat = 440, h: CGFloat = 540
            let sheet = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: 60, cornerHeight: 60, transform: nil)
            ctx.addPath(sheet); ctx.setLineWidth(58); ctx.strokePath()
            ctx.saveGState(); ctx.addPath(sheet); ctx.clip(); ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: 130)); ctx.restoreGState()
            ctx.setLineWidth(48)
            ctx.move(to: CGPoint(x: -w / 2 + 95, y: -h / 2 + 235)); ctx.addLine(to: CGPoint(x: w / 2 - 95, y: -h / 2 + 235)); ctx.strokePath()
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: -140, y: 130))
            wave.addCurve(to: CGPoint(x: -40, y: 120), control1: CGPoint(x: -110, y: 60), control2: CGPoint(x: -70, y: 180))
            wave.addCurve(to: CGPoint(x: 50, y: 110), control1: CGPoint(x: -10, y: 60), control2: CGPoint(x: 20, y: 170))
            ctx.addPath(wave); ctx.strokePath()
        }
        // The nib, tip on the page: a gap cleared around it, then the nib, with its slit cut out.
        local(CGPoint(x: 586, y: 652), 34, 0.6) {
            let body = CGMutablePath()
            body.move(to: CGPoint(x: -118, y: -490)); body.addLine(to: CGPoint(x: 118, y: -490))
            body.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 140, y: -320), control2: CGPoint(x: 52, y: -110))
            body.addCurve(to: CGPoint(x: -118, y: -490), control1: CGPoint(x: -52, y: -110), control2: CGPoint(x: -140, y: -320))
            body.closeSubpath()
            body.addRect(CGRect(x: -100, y: -660, width: 200, height: 190))  // the grip
            ctx.setBlendMode(.clear); ctx.addPath(body); ctx.setLineWidth(120); ctx.strokePath()
            ctx.setBlendMode(.normal); ctx.addPath(body); ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: -140, y: -500, width: 280, height: 36))  // the band between grip and nib
            ctx.setLineWidth(52); ctx.move(to: CGPoint(x: 0, y: -330)); ctx.addLine(to: CGPoint(x: 0, y: -60)); ctx.strokePath()  // the slit
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()
    }
}
