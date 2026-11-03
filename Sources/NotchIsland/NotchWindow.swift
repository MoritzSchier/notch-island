import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Ein randloses, transparentes Fenster oben in der Bildschirmmitte, das die Insel trägt.
/// Mausereignisse werden nur angenommen, wenn der Zeiger wirklich über der Insel ist –
/// sonst klickt man "durch" das Fenster in die Menüleiste.
final class NotchWindowController: NSObject {
    private(set) var screen: NSScreen
    let panel: NotchPanel
    private var timer: Timer?
    private var mouseWasDown = false
    private var dragBaseline = 0
    private var dropEndScheduled = false
    private var downInsideIsland = false
    private let model = IslandModel.shared
    static let windowSize = CGSize(width: 1100, height: 380)

    init(screen: NSScreen) {
        self.screen = screen
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        let host = FirstMouseHostingView(rootView: IslandRootView())
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        model.hostView = host

        updateGeometry()
        panel.orderFrontRegardless()

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func close() {
        timer?.invalidate()
        panel.orderOut(nil)
    }

    func updateGeometry() {
        let f = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        var n = CGSize(width: 200, height: max(24, NSStatusBar.system.thickness))
        if hasNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            n = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        model.notchSize = n
        model.hasNotch = hasNotch
        model.screenWidth = f.width
        let w = CGSize(width: min(Self.windowSize.width, f.width), height: min(Self.windowSize.height, f.height))
        panel.setFrame(NSRect(x: f.midX - w.width / 2, y: f.maxY - w.height, width: w.width, height: w.height), display: true)
    }

    /// Auf welchen Bildschirm gehört die Insel gerade? (Einstellung „Bildschirm“)
    static func targetScreen(mouse loc: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        switch UserDefaults.standard.string(forKey: Prefs.screenMode) ?? "mouse" {
        case "notch": return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        case "main": return NSScreen.screens.first
        default:
            // NSMouseInRect statt contains: der Zeiger ganz oben (y == maxY) zählt mit
            return screens.first { NSMouseInRect(loc, $0.frame, false) }
                ?? screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(loc) }
        }
    }

    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private var lastScreenCheck = Date.distantPast

    /// Wechselt die Insel bei Bedarf auf einen anderen Bildschirm – nur, solange sie zu ist und nichts gezogen wird.
    private func followScreen(_ loc: NSPoint) {
        guard Date().timeIntervalSince(lastScreenCheck) > 0.25 else { return }
        lastScreenCheck = Date()
        guard !model.isExpanded, !model.dropMode, NSEvent.pressedMouseButtons & 1 == 0,
              let s = Self.targetScreen(mouse: loc), Self.displayID(s) != Self.displayID(screen) else { return }
        screen = s
        updateGeometry()
        DevBridge.log("Insel auf Bildschirm: \(s.localizedName) · Notch \(s.safeAreaInsets.top > 0)")
    }

    private func tick() {
        let loc = NSEvent.mouseLocation
        followScreen(loc)
        let f = screen.frame
        let p = model.presentation
        let s = model.outerSize(p)
        var rect = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
        if model.secondary != nil { rect.size.width += model.notchSize.height + 10 }
        let hot: NSRect
        switch p {
        case .idle: hot = rect.insetBy(dx: -12, dy: -6)
        case .expanded: hot = rect.insetBy(dx: -10, dy: -14)
        default: hot = rect.insetBy(dx: -6, dy: -6)
        }
        let inside = hot.contains(loc)

        // Datei-Drag erkennen: Die Drag-Zwischenablage ändert sich, sobald irgendwo etwas gezogen wird.
        let down = (NSEvent.pressedMouseButtons & 1) == 1
        let dragPB = NSPasteboard(name: .drag)
        if down && !mouseWasDown { dragBaseline = dragPB.changeCount; downInsideIsland = inside }
        if down && dragPB.changeCount != dragBaseline {
            // Großzügige Zone: die Insel öffnet sich, bevor man die Bildschirmkante erreicht
            let zone = NSRect(x: f.midX - 450, y: f.maxY - 240, width: 900, height: 240)
            if zone.contains(loc) && !model.dropMode && model.draggingTab == nil && !downInsideIsland {
                let urls = (dragPB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                    .map { DropLoader.resolve($0) }
                model.dragURLs = urls
                model.beginDrop()
            }
        }
        if model.dropMode && !down && !dropEndScheduled && !model.holdDrop {
            dropEndScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.dropEndScheduled = false
                if (NSEvent.pressedMouseButtons & 1) == 0 { self?.model.endDrop() }
            }
        }
        if !down && model.draggingTab != nil { model.draggingTab = nil }
        if model.dropMode && model.draggingTab != nil { model.endDrop() }
        mouseWasDown = down

        let accept = (inside || model.dropMode) && !ColorStore.shared.picking
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }
        model.setHover(inside)
    }
}
