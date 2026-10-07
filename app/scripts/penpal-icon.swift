// Penpal's app icon (#209): C, the nib writing on the memo pad (Jason: "I like C, lets go with it").
// In the style of Workshop's factory (icon.swift): flat shapes, brick red and cream, a little snow on top,
// on Penpal's purple tile over a snowy hill. A and B were the other options, kept for reference.
// At 64 px and under it's drawn simpler (no snowflakes, holes, slit or second line, a bolder line of
// writing), so the Dock's and Finder's small sizes stay crisp.
// Usage: swift penpal-icon.swift <A|B|C> <out.png> [size]
//   A  a fountain pen nib with a drop of ink   🖋️
//   B  a memo pad with a pencil                📝
//   C  the nib writing on the memo pad         (Penpal's icon)
import AppKit

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1].uppercased() : "A"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "penpal-\(variant).png")
let px = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
let small = px <= 64

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
// Workshop's palette (no orange), with Penpal's purple for the tile.
let brick = rgb(0xD8473C), brickDark = rgb(0xB23329), cream = rgb(0xFFF6E6), snow = rgb(0xFFFFFF), lamp = rgb(0xFFEDB0)
let purpleTop = rgb(0x7B52B8), purpleBottom = rgb(0x46297A)
let ink = rgb(0x2B1F4F), line = rgb(0xC9B8E6), tan = rgb(0xF1DDB8), silver = rgb(0xCFCBD9), pink = rgb(0xF0A3B4)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let k = CGFloat(px) / 1024
ctx.scaleBy(x: k, y: k)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)  // a 1024 grid, y going down

func linear(_ top: CGColor, _ bottom: CGColor, _ y0: CGFloat, _ y1: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func fill(_ p: CGPath, _ c: CGColor) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }
func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CGColor) { ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
func stroke(_ pts: [CGPoint], _ w: CGFloat, _ c: CGColor) {
    ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.strokePath()
}
// Draw in a local frame: origin at `at`, turned by `deg` (clockwise on screen), scaled by `s`.
func local(_ at: CGPoint, _ deg: CGFloat, _ s: CGFloat, _ draw: () -> Void) {
    ctx.saveGState(); ctx.translateBy(x: at.x, y: at.y); ctx.rotate(by: deg * .pi / 180); ctx.scaleBy(x: s, y: s); draw(); ctx.restoreGState()
}

// The fountain pen nib, tip at the origin pointing down: brick body, cream band and slit, snow on top.
func nib() {
    ctx.setFillColor(brickDark); ctx.fill(CGRect(x: -96, y: -640, width: 192, height: 150))      // the section (grip)
    let body = CGMutablePath()
    body.move(to: CGPoint(x: -118, y: -490)); body.addLine(to: CGPoint(x: 118, y: -490))
    body.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 140, y: -320), control2: CGPoint(x: 52, y: -110))
    body.addCurve(to: CGPoint(x: -118, y: -490), control1: CGPoint(x: -52, y: -110), control2: CGPoint(x: -140, y: -320))
    body.closeSubpath()
    ctx.saveGState(); ctx.addPath(body); ctx.clip(); linear(brick, brickDark, -490, 0); ctx.restoreGState()
    ctx.setFillColor(cream); ctx.fill(CGRect(x: -128, y: -530, width: 256, height: 48))            // the cream band, like the chimney's
    if !small {
        dot(0, -330, 30, cream)                                                                      // breather hole
        stroke([CGPoint(x: 0, y: -296), CGPoint(x: 0, y: -18)], 13, cream)                          // the slit
    }
    stroke([CGPoint(x: -80, y: -640), CGPoint(x: 80, y: -640)], 30, snow)                           // snow on top
    dot(-40, -652, 20, snow); dot(28, -656, 24, snow)
}

// A pencil, tip at the origin pointing down: tan cone, ink-dark lead, brick body, silver band, pink eraser.
func pencil() {
    let cone = CGMutablePath(); cone.move(to: CGPoint(x: 0, y: 0)); cone.addLine(to: CGPoint(x: 44, y: -130)); cone.addLine(to: CGPoint(x: -44, y: -130)); cone.closeSubpath()
    fill(cone, tan)
    let lead = CGMutablePath(); lead.move(to: CGPoint(x: 0, y: 0)); lead.addLine(to: CGPoint(x: 15, y: -44)); lead.addLine(to: CGPoint(x: -15, y: -44)); lead.closeSubpath()
    fill(lead, ink)
    ctx.saveGState(); ctx.addRect(CGRect(x: -44, y: -480, width: 88, height: 352)); ctx.clip(); linear(brick, brickDark, -480, -128); ctx.restoreGState()
    ctx.setFillColor(brickDark); ctx.fill(CGRect(x: 16, y: -480, width: 28, height: 352))           // the shaded side
    ctx.setFillColor(silver); ctx.fill(CGRect(x: -46, y: -540, width: 92, height: 62))
    stroke([CGPoint(x: -40, y: -520), CGPoint(x: 40, y: -520)], 6, rgb(0x9E99AE))
    fill(CGPath(roundedRect: CGRect(x: -44, y: -610, width: 88, height: 76), cornerWidth: 24, cornerHeight: 24, transform: nil), pink)
    stroke([CGPoint(x: -26, y: -606), CGPoint(x: 26, y: -606)], 22, snow)                            // a cap of snow
}

// The memo pad: cream sheet, brick binding strip with snow along it, light purple lines.
func pad(_ w: CGFloat, _ h: CGFloat, lines n: Int) {
    let sheet = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.25)); fill(sheet, cream); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(sheet); ctx.clip()
    linear(brick, brickDark, -h / 2, -h / 2 + 110)  // the binding strip; the sheet below is painted cream next
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(sheet); ctx.clip()
    ctx.setFillColor(cream); ctx.fill(CGRect(x: -w / 2, y: -h / 2 + 110, width: w, height: h))
    ctx.restoreGState()
    for i in 0..<(small ? 0 : 5) { dot(-w / 2 + 70 + CGFloat(i) * (w - 140) / 4, -h / 2 + 58, 13, rgb(0x46297A, 0.55)) }   // the binding's holes
    stroke([CGPoint(x: -w / 2 + 34, y: -h / 2 + 4), CGPoint(x: w / 2 - 34, y: -h / 2 + 4)], 28, snow) // snow on top
    dot(-w / 2 + 96, -h / 2 - 8, 22, snow); dot(w / 2 - 120, -h / 2 - 10, 26, snow)
    for i in 0..<(small ? min(n, 1) : n) {
        let y = -h / 2 + 190 + CGFloat(i) * 78
        stroke([CGPoint(x: -w / 2 + 60, y: y), CGPoint(x: w / 2 - 60 - (i == n - 1 ? w * 0.3 : 0), y: y)], 16, line)
    }
}

// The tile and the snowy hill, as Workshop's.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.28))
fill(shape, purpleBottom)
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
linear(purpleTop, purpleBottom, 100, 924)
for (x, y, r) in [(230.0, 230.0, 12.0), (330.0, 170.0, 8.0), (800.0, 260.0, 10.0), (180.0, 420.0, 7.0), (850.0, 470.0, 7.0)] {
    if !small { dot(x, y, r, rgb(0xFFFFFF, 0.85)) }   // a few snowflakes
}
let ground = CGMutablePath()
ground.move(to: CGPoint(x: 80, y: 790))
ground.addCurve(to: CGPoint(x: 944, y: 770), control1: CGPoint(x: 380, y: 735), control2: CGPoint(x: 660, y: 735))
ground.addLine(to: CGPoint(x: 944, y: 944)); ground.addLine(to: CGPoint(x: 80, y: 944)); ground.closeSubpath()
fill(ground, cream)

switch variant {
case "B":
    local(CGPoint(x: 470, y: 530), -6, 1) { pad(420, 520, lines: 4) }
    local(CGPoint(x: 575, y: 668), 38, 0.78) { pencil() }
case "C":
    local(CGPoint(x: 450, y: 540), -6, 1) {
        pad(440, 540, lines: 2)
        // A line of handwriting, ending where the nib touches the page.
        let w = CGMutablePath()
        w.move(to: CGPoint(x: -160, y: 150))
        w.addCurve(to: CGPoint(x: -60, y: 140), control1: CGPoint(x: -130, y: 80), control2: CGPoint(x: -90, y: 200))
        w.addCurve(to: CGPoint(x: 40, y: 130), control1: CGPoint(x: -30, y: 80), control2: CGPoint(x: 10, y: 190))
        w.addCurve(to: CGPoint(x: 120, y: 120), control1: CGPoint(x: 70, y: 80), control2: CGPoint(x: 100, y: 170))
        ctx.addPath(w); ctx.setStrokeColor(ink); ctx.setLineWidth(small ? 30 : 18); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    }
    local(CGPoint(x: 586, y: 652), 34, 0.6) { nib() }
default:  // A
    // A drop of ink on the snow, just under the tip.
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: 420, y: 724))
    drop.addCurve(to: CGPoint(x: 420, y: 832), control1: CGPoint(x: 384, y: 780), control2: CGPoint(x: 374, y: 832))
    drop.addCurve(to: CGPoint(x: 420, y: 724), control1: CGPoint(x: 466, y: 832), control2: CGPoint(x: 456, y: 780))
    fill(drop, ink)
    dot(408, 802, 9, rgb(0xFFFFFF, 0.5))
    local(CGPoint(x: 432, y: 686), 32, 0.86) { nib() }
}
ctx.restoreGState()

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: out)
print(out.path, px)
