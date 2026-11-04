import AppKit
import IOKit
import SwiftUI

/// Entwicklungshilfe – standardmäßig AUS.
/// Nur wenn ein Entwickler sie bewusst einschaltet (`defaults write <Bundle-ID> devBridgeDir <Projektordner>`,
/// macht build.sh bei vorhandener Datei `.devbridge` automatisch), schreibt die App dort ein Log,
/// nimmt Befehle aus `.cmd` entgegen und speichert auf Wunsch ein Bild der Insel.
enum DevBridge {
    static let dir: URL = {
        let p = UserDefaults.standard.string(forKey: "devBridgeDir") ?? ""
        return URL(fileURLWithPath: p.isEmpty ? "/nonexistent" : (p as NSString).expandingTildeInPath)
    }()
    static let enabled: Bool = {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
            && fm.fileExists(atPath: dir.appendingPathComponent(".devbridge").path)
    }()
    private static var lastCmd: Date?
    private static var timer: Timer?

    static func start() {
        guard enabled else { return }
        log("Pfad \(Bundle.main.bundlePath) · gestartet · Notch \(IslandModel.shared.notchSize) · hasNotch \(IslandModel.shared.hasNotch) · AX \(AXIsProcessTrusted())")
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in poll() }
    }

    static func log(_ s: String) {
        guard enabled else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)\n"
        let url = dir.appendingPathComponent("runtime.log")
        // Log klein halten: über 5 MB → neu beginnen
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func poll() {
        let url = dir.appendingPathComponent(".cmd")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = attrs[.modificationDate] as? Date, m != lastCmd,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let first = lastCmd == nil
        lastCmd = m
        if first && Date().timeIntervalSince(m) > 5 { return }
        for line in text.split(separator: "\n") {
            run(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func run(_ cmd: String) {
        let parts = cmd.split(separator: " ").map(String.init)
        guard let c = parts.first else { return }
        let model = IslandModel.shared
        log("cmd: \(cmd)")
        switch c {
        case "expand":
            let t = parts.count > 1 ? IslandTab(rawValue: parts[1]) : nil
            model.expand(tab: t)
            model.pinned = true
        case "widget":
            if parts.count > 1, let w = WidgetTab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(parts[1]) }) {
                model.widgetTab = w
            }
        case "expandfree":
            model.expand(tab: parts.count > 1 ? IslandTab(rawValue: parts[1]) : nil)
        case "collapse": model.collapse()
        case "drop": model.holdDrop = true; model.beginDrop()
        case "enddrop": model.holdDrop = false; model.endDrop()
        case "toast":
            model.show(Toast(symbol: "airpodspro", tint: .white, title: "AirPods Pro", subtitle: "Verbunden", trailing: .ring(0.82), duration: 4))
        case "charge":
            model.show(Toast(symbol: "bolt.fill", tint: .green, title: "Lädt", trailing: .battery(BatteryMonitor.shared.level, charging: true), duration: 4))
        case "hud": model.showHUD(.volume(0.6, muted: false))
        case "timer": TimerService.shared.start(seconds: Double(parts.count > 1 ? Int(parts[1]) ?? 300 : 300))
        case "canceltimers": TimerService.shared.timers.forEach { TimerService.shared.cancel($0.id) }
        case "demo": ClaudeService.shared.demo()
        case "color": if parts.count > 1, let c = RGBColor(hex: parts[1]) { ColorStore.shared.set(c) }
        case "clip": if parts.count > 1 { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(parts.dropFirst().joined(separator: " "), forType: .string) }
        case "battery":
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any] {
                let keys = d.keys.sorted().map { k -> String in
                    let v = d[k]
                    if let n = v as? NSNumber { return "\(k)=\(n)" }
                    if let dd = v as? [String: Any] { return "\(k)={" + dd.keys.sorted().map { "\($0)=\(dd[$0] is NSNumber ? "\(dd[$0]!)" : "…")" }.joined(separator: ",") + "}" }
                    return k
                }
                log("Akku: " + keys.joined(separator: " | "))
            }
            IOObjectRelease(svc)
        case "convert":
            if parts.count > 2, let t = ConvertTarget(rawValue: parts[1]) {
                Converter.convert([URL(fileURLWithPath: parts.dropFirst(2).joined(separator: " "))], to: t)
            }
        case "compress":
            if parts.count > 1 { Compressor.compress([URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))]) }
        case "import":
            if parts.count > 1 { ShelfStore.shared.importCopies([URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))]) }
        case "shelfstate":
            log("Ablage: " + ShelfStore.shared.items.map { $0.name + " @ " + $0.path }.joined(separator: " | "))
        case "dragtest":
            model.dragURLs = parts.dropFirst().joined(separator: " ").components(separatedBy: "|").map { URL(fileURLWithPath: $0) }
            model.holdDrop = true; model.beginDrop()
        case "usage": ClaudeUsage.shared.refresh { log("Nutzung: \(ClaudeUsage.shared.state) \(ClaudeUsage.shared.windows.map { "\($0.key)=\($0.utilization)" })") }
        case "perm": ClaudeService.shared.demoPermission()
        case "permclear": ClaudeService.shared.openClaudeForPermission(); ClaudeService.shared.permissionIsDemo = false
        case "axdump": log("AX=\(AXIsProcessTrusted()) perm=\(String(describing: ClaudeService.shared.permission?.options.map(\.label))) Claude-Knöpfe: " + ClaudeService.shared.lastButtonLabels.joined(separator: " | "))
        case "caldump":
            let cal = CalendarService.shared
            cal.refresh()
            let sources = cal.store.calendars(for: .event).map { "\($0.source.title)/\($0.title)" }
            log("Kalender (\(sources.count)): " + sources.joined(separator: " | "))
            for e in cal.events.prefix(8) {
                log("Termin: \(e.startDate!) \(e.title ?? "?") · \(e.calendar.source.title)/\(e.calendar.title)")
            }
        case "state":
            log("presentation=\(model.presentation) activities=\(model.activities) media=\(String(describing: MediaController.shared.now)) inputs=\(AudioProcessMonitor.shared.inputApps) outputs=\(AudioProcessMonitor.shared.outputApps) claude=\(String(describing: ClaudeService.shared.current)) badges=\(DockBadgeMonitor.shared.badges.count) cal=\(CalendarService.shared.authorized)")
        case "snap":
            let delay = parts.count > 1 ? Double(parts[1]) ?? 0.8 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshot(name: parts.count > 2 ? parts[2] : "snap") }
        case "axtree":
            // axtree <Sekunden> – Bedienungshilfen-Baum der Claude-App nach kurzer Wartezeit in axtree.txt
            let delay = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Const.claudeBundle).first else { return }
                let txt = AXDump.tree(AXUIElementCreateApplication(app.processIdentifier), maxNodes: 9000)
                try? txt.write(to: dir.appendingPathComponent("axtree.txt"), atomically: true, encoding: .utf8)
                log("axtree.txt geschrieben (\(txt.count) Zeichen)")
            }
        case "axwatch":
            // axwatch <Sekunden> – schreibt den Claude-Baum jedes Mal, wenn sich die Knöpfe ändern (axwatch_N.txt)
            let total = parts.count > 1 ? Double(parts[1]) ?? 120 : 120
            let end = Date().addingTimeInterval(total)
            var lastButtons = ""
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                guard Date() < end, n < 25,
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: Const.claudeBundle).first else { t.invalidate(); return }
                let txt = AXDump.tree(AXUIElementCreateApplication(app.processIdentifier), maxNodes: 9000)
                let buttons = txt.split(separator: "\n").filter { $0.contains("AXButton") || $0.contains("AXRadioButton") || $0.contains("AXCheckBox") }.joined(separator: "\n")
                if buttons != lastButtons {
                    lastButtons = buttons
                    n += 1
                    try? txt.write(to: dir.appendingPathComponent("axwatch_\(n).txt"), atomically: true, encoding: .utf8)
                    log("axwatch_\(n).txt (\(txt.count) Zeichen)")
                }
            }
        case "ncwatch":
            // ncwatch <Sekunden> – speichert den Baum der Mitteilungszentrale, sobald ein Banner (kein Widget) da ist
            let total = parts.count > 1 ? Double(parts[1]) ?? 600 : 600
            let end = Date().addingTimeInterval(total)
            var n = 0
            var last = ""
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                guard Date() < end, n < 6 else { t.invalidate(); return }
                let txt = NotificationBannerMonitor.dump()
                let wins = txt.split(separator: "\n").filter { $0.hasPrefix("  AXWindow") }
                let nonWidget = wins.filter { !$0.contains("widget") && !$0.contains("t=\"Liste\"") && !$0.contains("Batteriestatus") }
                guard !nonWidget.isEmpty, txt != last else { return }
                last = txt
                n += 1
                try? txt.write(to: dir.appendingPathComponent("ncwatch_\(n).txt"), atomically: true, encoding: .utf8)
                log("ncwatch_\(n).txt – Fenster: \(nonWidget.joined(separator: " | "))")
            }
        case "notestate":
            let fdaProbe = NSHomeDirectory() + "/Library/Safari"
            log("FDA-Probe (~/Library/Safari lesbar): \((try? FileManager.default.contentsOfDirectory(atPath: fdaProbe)) != nil)")
            for c in NotificationDBMonitor.candidatePaths {
                let fd = open(c, O_RDONLY)
                log("open \(c): fd=\(fd) errno=\(fd < 0 ? String(cString: strerror(errno)) : "ok")")
                if fd >= 0 { close(fd) }
                let dirOK = (try? FileManager.default.contentsOfDirectory(atPath: (c as NSString).deletingLastPathComponent)) != nil
                log("Ordner lesbar: \(dirOK)")
            }
            log("Mitteilungs-DB: \(NotificationDBMonitor.path ?? "nicht lesbar") · Kandidaten: \(NotificationDBMonitor.candidatePaths) · exists: \(NotificationDBMonitor.candidatePaths.map { FileManager.default.fileExists(atPath: $0) })")
        case "testmsg":
            let texts = ["Hey! Kommst du heute Abend auch mit ins Kino? 🎬", "Wir treffen uns um 19:30 vor dem Eingang, ich hab schon Karten für uns alle besorgt.", "Sag Bescheid ✌️"]
            let i = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            NotificationBannerMonitor.shared.deliver(bundleID: "net.whatsapp.WhatsApp", title: "Anna", subtitle: nil, body: texts[i % texts.count], element: nil)
        case "lang": if parts.count > 1 { UserDefaults.standard.set(parts[1], forKey: Loc.key) }
        case "setup": SetupWindow.show()
        case "setupsnaps":
            // Bilder aller Assistenten-Seiten (setup_N.png)
            for s in SetupView.Step.allCases {
                let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
                let v = NSHostingView(rootView: SetupView(onFinish: {}, initialStep: s))
                v.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
                w.contentView = v
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(s.rawValue) * 0.1) {
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent("setup_\(s.rawValue).png"))
                        }
                    }
                    w.orderOut(nil)
                }
            }
        case "settings": (NSApp.delegate as? AppDelegate)?.openSettings()
        case "hooktest":
            // hooktest <n> – startet n Claude-Code-Hook-Anfragen (wie von mehreren Agenten), Ausgabe in hookout_<i>.txt
            let n = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            for i in 1...max(1, n) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/notch-mcp")
                p.arguments = ["--hook", "permission"]
                let inPipe = Pipe()
                p.standardInput = inPipe
                let outURL = dir.appendingPathComponent("hookout_\(i).txt")
                FileManager.default.createFile(atPath: outURL.path, contents: nil)
                p.standardOutput = try? FileHandle(forWritingTo: outURL)
                try? p.run()
                let json = "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test # Agent \(i)\"},\"cwd\":\"/tmp/projekt-\(i)\"}"
                inPipe.fileHandleForWriting.write(json.data(using: .utf8)!)
                try? inPipe.fileHandleForWriting.close()
            }
        case "sessiontest":
            let c = ClaudeService.shared
            c.handleExternal(["kind": "claude", "source": "code", "state": "running", "session": "a1", "project": "notch-island", "term": "Apple_Terminal", "detail": "Tests reparieren"])
            c.handleExternal(["kind": "claude", "source": "code", "state": "running", "session": "b2", "project": "website", "term": "vscode", "activity": "Bash: npm run build"])
            c.handleExternal(["kind": "claude", "source": "code", "state": "waiting", "session": "c3", "project": "uni-skript", "detail": "Claude needs your permission to use Bash"])
            c.handleExternal(["kind": "claude", "source": "code", "state": "done", "session": "d4", "project": "notizen"])
        case "answer":
            // answer <Beschriftung> – drückt in der aktuellen Anfrage den Knopf mit dieser Beschriftung
            let label = parts.dropFirst().joined(separator: " ")
            if let o = ClaudeService.shared.permission?.options.first(where: { $0.label == label }) { ClaudeService.shared.respond(o) }
        case "selfax":
            let txt = AXDump.tree(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier), maxNodes: 600)
            try? txt.write(to: dir.appendingPathComponent("selfax.txt"), atomically: true, encoding: .utf8)
            log("selfax.txt")
        case "settingssnap":
            // settingssnap <seite> – Einstellungen öffnen und Fenster als settings_<seite>.png speichern
            let pg = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            UserDefaults.standard.set(pg, forKey: "settingsPage")
            (NSApp.delegate as? AppDelegate)?.openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 700 }), let v = w.contentView?.superview ?? w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("settings_\(pg).png"))
                    log("settings_\(pg).png")
                }
            }
        case "notedb": log("DB:\n" + NotificationDBMonitor.debugDescription())
        case "testnotify":
            // Test-Mitteilung über osascript (erscheint als „Skripteditor“)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"Hallo, das ist eine Testnachricht\" with title \"Test-Absender\" subtitle \"Notch Island\""]
            try? p.run()
        case "ncdump":
            let delay = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let txt = NotificationBannerMonitor.dump()
                try? txt.write(to: dir.appendingPathComponent("nctree.txt"), atomically: true, encoding: .utf8)
                log("nctree.txt geschrieben (\(txt.count) Zeichen)")
            }
        case "question": ClaudeService.shared.demoQuestion()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    static func snapshot(name: String) {
        guard let v = model().hostView else { return }
        let size = model().outerSize(model().presentation)
        let pad: CGFloat = 40
        let rectW = min(v.bounds.width, size.width + 2 * pad + 60)
        let rectH = min(v.bounds.height, size.height + pad)
        // AppKit-Koordinaten: Ursprung unten links
        let r = NSRect(x: (v.bounds.width - rectW) / 2, y: v.isFlipped ? 0 : v.bounds.height - rectH, width: rectW, height: rectH)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return }
        v.cacheDisplay(in: r, to: rep)
        // auf grauen Hintergrund legen, damit Schwarz sichtbar wird
        let img = NSImage(size: r.size)
        img.lockFocus()
        NSColor(white: 0.82, alpha: 1).setFill()
        NSRect(origin: .zero, size: r.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: r.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let b = NSBitmapImageRep(data: tiff),
           let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            log("snapshot \(name).png \(Int(r.width))x\(Int(r.height))")
        }
    }

    private static func model() -> IslandModel { IslandModel.shared }
}
