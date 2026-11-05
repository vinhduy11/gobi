import AppKit

/// Draws everything that changed since the last paint. In this setup `NSWindow.displayIfNeeded()` paints nothing (it
/// was measured in every window state); `CATransaction.flush()` is what puts the changes on screen, so all paint
/// measurements go through this function.
public func flushPendingPaint() {
    CATransaction.flush()
}
