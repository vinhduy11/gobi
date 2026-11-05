import AppKit

/// Paints a window's content into a PNG for the quiet self-tests. A bare view does not paint the window's background, so
/// the background is laid down first, in the window's own appearance.
enum WindowSnapshot {
    static func write(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window?.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
                view.displayIgnoringOpacity(view.bounds, in: context)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}
