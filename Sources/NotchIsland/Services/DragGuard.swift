import AppKit
import CoreGraphics
import ApplicationServices

/// Verhindert, dass beim Ziehen (Dateien, Tabs, Fenster) versehentlich Mission Control, aktive Ecken
/// oder die Spaces-Leiste ausgelöst werden: Solange die Maustaste gedrückt ist, kann der Zeiger die
/// obere Kante im Notch-Bereich und die vier Bildschirmecken nicht ganz berühren (es fehlen nur 3 Pixel).
final class DragGuard {
    static let shared = DragGuard()
    fileprivate var tap: CFMachPort?
    private var retry: Timer?

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Ohne Bedienungshilfen-Freigabe geht es nicht – später erneut versuchen
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    if AXIsProcessTrusted() { self?.retry?.invalidate(); self?.retry = nil; self?.start() }
                }
            }
            return
        }
        let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: dragGuardCallback, userInfo: nil) else {
            DevBridge.log("DragGuard: Event-Tap konnte nicht erstellt werden")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        DevBridge.log("DragGuard aktiv")
    }

    static let margin: CGFloat = 3
    static let notchHalfWidth: CGFloat = 460

    static func clamp(_ p: CGPoint) -> CGPoint? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetDisplaysWithPoint(p, 8, &ids, &count) == .success, count > 0 else { return nil }
        let b = CGDisplayBounds(ids[0])
        var q = p
        let nearLeft = p.x <= b.minX + margin, nearRight = p.x >= b.maxX - 1 - margin
        let atTop = p.y <= b.minY + margin, atBottom = p.y >= b.maxY - 1 - margin
        // Obere Kante im Bereich der Notch (Spaces-Leiste / Mission Control)
        if atTop && abs(p.x - b.midX) < notchHalfWidth { q.y = b.minY + margin + 1 }
        // Aktive Ecken
        if (atTop || atBottom) && (nearLeft || nearRight) {
            q.y = atTop ? b.minY + margin + 1 : b.maxY - 2 - margin
        }
        return q == p ? nil : q
    }
}

private func dragGuardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = DragGuard.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if let q = DragGuard.clamp(event.location) {
        event.location = q
        CGWarpMouseCursorPosition(q)
    }
    return Unmanaged.passUnretained(event)
}
