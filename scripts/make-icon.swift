import AppKit

let destination = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: destination, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
        let accent = NSColor(calibratedRed: 0.35, green: 0.46, blue: 0.23, alpha: 1)
        accent.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 256, y: 256, width: 512, height: 512))
        ring.lineWidth = 65
        ring.stroke()
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 416, y: 416, width: 192, height: 192)).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: directory.appendingPathComponent(name))
    }
}
