import AppKit
import SwiftUI
import ServiceManagement

@main
enum NotchIslandMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchWindowController] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        DevBridge.log("didFinishLaunching")

        buildWindows()
        setupStatusItem()
        setupEditMenu()
        // Sprache gewechselt → Menüs neu aufbauen
        var lastLang = Loc.current
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard Loc.current != lastLang else { return }
            lastLang = Loc.current
            self?.setupStatusItem()
            self?.setupEditMenu()
        }
        // Dienste erst nach dem ersten Bild starten – falls macOS nach Berechtigungen fragt, ist die Insel schon da.
        DispatchQueue.main.async {
            AudioProcessMonitor.shared.start()
            CallMonitor.shared.start()
            VolumeController.shared.start()
            BrightnessMonitor.shared.start()
            BatteryMonitor.shared.start()
            BluetoothMonitor.shared.start()
            CalendarService.shared.start()
            MediaController.shared.start()
            ClaudeService.shared.start()
            SessionStore.shared.start()
            DockBadgeMonitor.shared.start()
            NotificationBannerMonitor.shared.start()
            NotificationDBMonitor.shared.start()
            DownloadMonitor.shared.start()
            ClipboardHistory.shared.start()
            CameraMonitor.shared.start()
            AudioDevices.shared.start()
            DragGuard.shared.start()
            ClaudeUsage.shared.start()
            RemindersService.shared.start()
            Updater.shared.start()
            HookChannel.cleanup()
            _ = ShelfStore.shared
            DevBridge.log("Dienste gestartet")
            IslandModel.shared.bind()
        }
        DevBridge.start()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(externalActivity(_:)),
            name: Const.activityNotification, object: nil, suspensionBehavior: .deliverImmediately)

        // Beim ersten Start automatisch bei der Anmeldung starten (abschaltbar in den Einstellungen)
        if !UserDefaults.standard.bool(forKey: "didSetupLoginItem") {
            UserDefaults.standard.set(true, forKey: "didSetupLoginItem")
            try? SMAppService.mainApp.register()
        }

        // Erster Start: Einrichtungsassistent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { SetupWindow.showIfNeeded() }

        // Begrüßung
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            IslandModel.shared.show(Toast(symbol: "sparkles", tint: .white, title: tr("Notch Island ist aktiv"),
                                          subtitle: tr("Zeige mit der Maus auf die Notch"), duration: 3))
        }
    }

    // MARK: Fenster

    private func notchScreen() -> NSScreen? {
        NotchWindowController.targetScreen(mouse: NSEvent.mouseLocation)
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func buildWindows() {
        controllers.forEach { $0.close() }
        controllers = []
        if let s = notchScreen() { controllers.append(NotchWindowController(screen: s)) }
    }

    @objc private func screensChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.buildWindows() }
    }

    // MARK: Externe Ereignisse

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        ClaudeService.shared.handle(url: url)
    }

    @objc private func externalActivity(_ note: Notification) {
        guard let json = note.object as? String, let data = json.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        DispatchQueue.main.async { ClaudeService.shared.handleExternal(d) }
    }

    // MARK: Menüleiste

    /// Hintergrund-Apps haben keine Menüleiste – ohne „Bearbeiten“-Menü funktionieren
    /// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z in Textfeldern nicht. Daher ein (unsichtbares) Hauptmenü mit diesen Befehlen.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Notch Island beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Bearbeiten"))
        edit.addItem(withTitle: tr("Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Wiederholen"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: tr("Notch Island"))
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Insel öffnen"), action: #selector(openIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Einstellungen …"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: tr("Einrichtung …"), action: #selector(openSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Nach Updates suchen"), action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Notch Island beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openIsland() {
        IslandModel.shared.expand()
        IslandModel.shared.hold("menu", max: 8)
    }

    @objc private func openSetup() { SetupWindow.show() }

    @objc private func checkUpdates() {
        Updater.shared.check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            switch Updater.shared.state {
            case .upToDate: IslandModel.shared.show(Toast(symbol: "checkmark.circle.fill", tint: .green, title: tr("Notch Island ist aktuell"), subtitle: tr("Version \(Updater.shared.currentVersion)"), duration: 3))
            case .notConfigured: IslandModel.shared.show(Toast(symbol: "questionmark.circle", tint: .orange, title: tr("Kein Update-Repository"), subtitle: tr("Einstellungen › Update"), duration: 3))
            case .failed(let e): IslandModel.shared.show(Toast(symbol: "exclamationmark.triangle.fill", tint: .orange, title: tr("Update-Prüfung fehlgeschlagen"), subtitle: e, duration: 4))
            default: break
            }
        }
    }

    @objc func openSettings() {
        IslandModel.shared.collapse()
        if settingsWindow == nil {
            // NSHostingController statt nackter NSHostingView: SwiftUI-Listen/Formulare brauchen
            // die View-Controller-Einbindung, sonst bleibt das Fenster leer.
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = tr("Notch Island")
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 620))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
