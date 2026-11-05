// Renders Resources/AppIcon.svg into an .iconset folder (usage: swift scripts/make-icon.swift SVG ICONSET_DIR).
// macOS app icons keep a margin around the artwork, so the SVG is drawn at 80% of the canvas, centred.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift SVG ICONSET_DIR (the SVG must load as an NSImage)\n".utf8))
    exit(2)
}
let output = arguments[2]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(pixels) * 0.8
    let origin = (CGFloat(pixels) - side) / 2
    source.draw(in: NSRect(x: origin, y: origin, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

// The sizes iconutil expects: name -> pixel size.
let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in files {
    guard let png = render(pixels: pixels) else { print("cannot render \(name)"); exit(1) }
    try png.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}
print("wrote \(files.count) images to \(output)")
