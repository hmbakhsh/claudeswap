// Draws the 1024px app icon: warm gradient tile with two thick, round-capped swap arrows.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Tile on Apple's macOS icon grid (824px body, ~185px corner radius) with a soft drop shadow.
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
tileShadow.shadowBlurRadius = 28
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.set()
NSColor.black.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(red: 0.97, green: 0.56, blue: 0.36, alpha: 1),
    NSColor(red: 0.88, green: 0.40, blue: 0.22, alpha: 1),
    NSColor(red: 0.74, green: 0.27, blue: 0.14, alpha: 1),
])!.draw(in: tilePath, angle: -90)

// Gentle top sheen and a hairline inner edge, like Apple's own icons.
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
edge.lineWidth = 6
NSColor.white.withAlphaComponent(0.14).setStroke()
edge.stroke()

// Two arcs around the centre, each ending in a rounded arrowhead pointing clockwise.
let center = NSPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 218
let stroke: CGFloat = 98
let gap: CGFloat = 22           // degrees left open either side of each arrowhead
let headLength: CGFloat = 138
let headHalfWidth: CGFloat = 100
let headLean: CGFloat = 14       // degrees

func point(_ deg: CGFloat, _ r: CGFloat = radius) -> NSPoint {
    let a = deg * .pi / 180
    return NSPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
}

let glyphShadow = NSShadow()
glyphShadow.shadowColor = NSColor(red: 0.35, green: 0.10, blue: 0.04, alpha: 0.35)
glyphShadow.shadowBlurRadius = 18
glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
let ctx = NSGraphicsContext.current!.cgContext
NSGraphicsContext.saveGraphicsState()
glyphShadow.set()
ctx.beginTransparencyLayer(auxiliaryInfo: nil)  // shadow the arrows as one shape
NSColor.white.set()
for (start, end) in [(180 - gap, gap + 14), (360 - gap, 180 + gap + 14)] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    arc.stroke()

    // Arrowhead at the clockwise end, pointing along the tangent.
    let a = end * .pi / 180
    let t = NSPoint(x: sin(a), y: -cos(a))
    let lean = headLean * .pi / 180  // turn the tip inward so it follows the curve
    let dir = NSPoint(x: t.x * cos(lean) + t.y * sin(lean), y: -t.x * sin(lean) + t.y * cos(lean))
    let base = point(end)
    let tip = NSPoint(x: base.x + dir.x * headLength, y: base.y + dir.y * headLength)
    let head = NSBezierPath()
    head.move(to: tip); head.line(to: point(end, radius + headHalfWidth)); head.line(to: point(end, radius - headHalfWidth)); head.close()
    head.lineWidth = 34
    head.lineJoinStyle = .round
    head.fill()
    head.stroke()
}
ctx.endTransparencyLayer()
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
