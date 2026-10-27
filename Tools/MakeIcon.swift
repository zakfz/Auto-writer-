import AppKit

let output = CommandLine.arguments[1]
let manager = FileManager.default
try manager.createDirectory(atPath: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let inset = Double(size) * 0.065
        let rect = NSRect(x: inset, y: inset, width: Double(size) - 2 * inset, height: Double(size) - 2 * inset)
        NSColor(red: 0.84, green: 0.29, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Double(size) * 0.20, yRadius: Double(size) * 0.20).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Double(size) * 0.58, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        ("a" as NSString).draw(at: NSPoint(x: Double(size) * 0.25, y: Double(size) * 0.19), withAttributes: attributes)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: Double(size) * 0.65, y: Double(size) * 0.25,
                                       width: max(1, Double(size) * 0.025), height: Double(size) * 0.48),
                     xRadius: Double(size) * 0.01, yRadius: Double(size) * 0.01).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
