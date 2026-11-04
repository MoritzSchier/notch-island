import AppKit
import SwiftUI

enum Const {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.notchisland" }
    /// Gemeinsamer Name mit dem MCP-Helfer (notch-mcp) – unabhängig von der Bundle-ID.
    static let activityNotification = Notification.Name("notchisland.activity")
    /// Antwort der Insel an wartende Claude-Code-Hooks
    static let replyNotification = Notification.Name("notchisland.reply")
    static let claudeBundle = "com.anthropic.claudefordesktop"
    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"
    static let chrome = "com.google.Chrome"
}

enum Prefs {
    static let hoverToOpen = "hoverToOpen"
    static let haptics = "haptics"
    static let showMedia = "showMedia"
    static let showVolumeHUD = "showVolumeHUD"
    static let showBrightnessHUD = "showBrightnessHUD"
    static let showBattery = "showBattery"
    static let showBluetooth = "showBluetooth"
    static let showCalendar = "showCalendar"
    static let showSessions = "showSessions"
    static let detectCalls = "detectCalls"
    static let detectClaude = "detectClaude"
    static let showDownloads = "showDownloads"
    static let showBadges = "showBadges"
    static let clipboardHistory = "clipboardHistory"
    static let downloadsToShelf = "downloadsToShelf"
    static let showPrivacy = "showPrivacy"
    static let quickNote = "quickNote"
    static let customFolders = "customFolders"
    static let defaultTab = "defaultTab"
    static let claudePrimary = "claudePrimary"
    static let showReminders = "showReminders"
    static let showBanners = "showBanners"
    static let screenMode = "screenMode"
    /// Auf Bildschirmen ohne Notch dauerhaft eine schwarze Notch zeigen
    static let simulateNotch = "simulateNotch"

    static func registerDefaults() {
        Opt.register()
        UserDefaults.standard.register(defaults: [
            hoverToOpen: true, haptics: true, showMedia: true, showVolumeHUD: true, showBrightnessHUD: true,
            showBattery: true, showBluetooth: true, showCalendar: true, showSessions: true, detectCalls: true, detectClaude: true,
            showDownloads: true, showBadges: true, clipboardHistory: true, downloadsToShelf: false, showPrivacy: true,
            defaultTab: "auto", claudePrimary: "auto", showReminders: true, showBanners: true, screenMode: "mouse", simulateNotch: false,
        ])
    }

    static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var folders: [String] {
        get { UserDefaults.standard.stringArray(forKey: customFolders) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: customFolders) }
    }
}

enum AppInfo {
    /// Ist die App wirklich sichtbar im Vordergrund (aktiv UND mit Fenster auf dem Bildschirm)?
    /// Minimiert oder ohne offenes Fenster zählt nicht – dann sollen ihre Mitteilungen in der Insel erscheinen.
    static func isVisiblyFrontmost(_ bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier?.lowercased() == bundleID.lowercased() else { return false }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && ((w[kCGWindowBounds as String] as? [String: Any]).flatMap { ($0["Height"] as? NSNumber)?.doubleValue } ?? 0) > 100
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage? {
        if let i = iconCache[bundleID] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = i
        return i
    }

    static func name(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return humanize(bundleID)
    }

    static func activate(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            if let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Bekannte System-Prozesse mit verständlichem Namen
    private static var friendly: [String: String] { [
        "com.apple.notificationcenterui": tr("Mitteilungen"),
        "com.apple.UserNotificationCenter": tr("Mitteilungen"),
        "com.apple.usernotificationsd": tr("Mitteilungen"),
        "com.apple.systempreferences": tr("Systemeinstellungen"),
        "com.apple.controlcenter": tr("Kontrollzentrum"),
        "com.apple.dock": tr("Dock"),
        "com.apple.finder": tr("Finder"),
        "com.apple.FaceTime": "FaceTime",
        "com.apple.MobileSMS": tr("Nachrichten"),
        "com.apple.mail": tr("Mail"),
        "com.apple.iCal": tr("Kalender"),
        "com.cron.electron": "Notion Calendar",
        "com.apple.reminders": tr("Erinnerungen"),
        "com.apple.Safari": tr("Safari"),
        "com.apple.WebKit.GPU": tr("Safari"),
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.hnc.Discord": tr("Discord"),
        "com.anthropic.claudefordesktop": tr("Claude"),
        "com.apple.telephonyutilities.callservicesd": tr("Telefon"),
        "com.apple.TelephonyUtilities": tr("Telefon"),
    ] }

    static func looksLikeBundleID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
    }

    /// Macht aus Kennungen wie „com.apple.notificationcenterui“ einen lesbaren Namen („Mitteilungen“).
    static func humanize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeBundleID(t) else { return s }
        if let f = friendly[t] { return f }
        if let f = friendly.first(where: { t.hasPrefix($0.key + ".") })?.value { return f }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: t).first, let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t) { return url.deletingPathExtension().lastPathComponent }
        // Hilfsprozess einer laufenden App? („com.google.Chrome.helper“ → Chrome)
        if let parent = NSWorkspace.shared.runningApplications.first(where: { a in
            guard let b = a.bundleIdentifier else { return false }
            return t.hasPrefix(b + ".")
        }), let n = parent.localizedName { return n }
        var last = t.components(separatedBy: ".").last ?? t
        for suffix in ["d", "agent", "helper", "service", "ui"] where last.lowercased().hasSuffix(suffix) && last.count > suffix.count + 3 {
            last = String(last.dropLast(suffix.count)); break
        }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    static var frontmost: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

func haptic() {
    guard Prefs.on(Prefs.haptics) else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let dim = Color.white.opacity(0.58)
    static let cardFill = Color.white.opacity(0.075)
}

/// 1:05 / 1:02:03
func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Restzeit eines Timers (aufgerundet, wie auf dem iPhone)
func formatRemaining(_ t: TimeInterval) -> String {
    formatDuration(t.rounded(.up))
}

func formatStopwatch(_ t: TimeInterval) -> String {
    let cs = Int((t * 100).rounded(.down))
    let m = cs / 6000, s = (cs / 100) % 60, c = cs % 100
    return String(format: "%02d:%02d,%02d", m, s, c)
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func showToast(_ t: Toast) {
    DispatchQueue.main.async { IslandModel.shared.show(t) }
}
