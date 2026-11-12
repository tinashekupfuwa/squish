import AppKit

// Renders the app icon: a gradient squircle with a film-strip "squeeze" glyph.
let output = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.72, alpha: 1), NSColor(calibratedRed: 0.29, green: 0.25, blue: 0.86, alpha: 1)])!.draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 40, width: s.width, height: s.height))
}
if let arrows = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 150, weight: .bold).applying(.init(paletteColors: [.white]))) {
    let s = arrows.size
    arrows.draw(in: NSRect(x: (size - s.width) / 2, y: 175, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
