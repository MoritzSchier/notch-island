import AppKit
import SwiftUI
import WebKit

/// Nutzungslimit von Claude (5-Stunden-Fenster und Wochenlimit), wie unter claude.ai › Einstellungen › Nutzung.
/// Die App hat dafür ein eigenes, kleines claude.ai-Fenster: Du meldest dich dort einmal selbst an,
/// danach liest die App nur die Nutzungswerte deines Kontos aus. Passwörter oder Tokens sieht oder speichert sie nicht.
final class ClaudeUsage: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeUsage()

    struct Window: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let label: String
        let short: String
        let utilization: Double      // 0…100
        let resetsAt: Date?
    }

    enum State: Equatable { case unknown, loading, loggedOut, ok, error(String) }

    @Published private(set) var windows: [Window] = []
    @Published private(set) var state: State = .unknown
    @Published private(set) var updatedAt: Date?

    private var webView: WKWebView!
    private var hostWindow: NSWindow!
    private var loginWindow: NSWindow?
    private var timer: Timer?
    private var pageReady = false
    private var pending: [(() -> Void)] = []

    var session: Window? { windows.first { $0.key == "five_hour" } }
    var week: Window? { windows.first { $0.key == "seven_day" } }

    func start() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: cfg)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        // Unsichtbares Fenster, damit die Seite normal läuft
        hostWindow = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.contentView = webView
        hostWindow.isReleasedWhenClosed = false
        state = .loading
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        refresh()
        let p = pending
        pending = []
        p.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .error(tr("Keine Verbindung zu claude.ai"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .error(tr("Keine Verbindung zu claude.ai"))
    }

    private static let script = """
    const or = await fetch('/api/organizations', {credentials: 'include'});
    if (or.status === 401 || or.status === 403) { return {error: 'login'}; }
    const orgs = await or.json();
    if (!Array.isArray(orgs) || orgs.length === 0) { return {error: 'login'}; }
    const org = orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
    const r = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
    if (r.status === 401 || r.status === 403) { return {error: 'login'}; }
    if (!r.ok) { return {error: 'http ' + r.status}; }
    return {usage: JSON.stringify(await r.json())};
    """

    /// Werte neu laden; `completion` wird spätestens nach 3 Sekunden aufgerufen.
    func refresh(completion: (() -> Void)? = nil) {
        guard webView != nil else { completion?(); return }
        guard pageReady else {
            if let completion { pending.append(completion) }
            return
        }
        var done = false
        func finish() { if !done { done = true; completion?() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        webView.callAsyncJavaScript(Self.script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let d = value as? [String: Any] ?? [:]
                if let err = d["error"] as? String {
                    self.state = err == "login" ? .loggedOut : .error(err)
                } else if let json = d["usage"] as? String, let data = json.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.parse(obj)
                    self.state = .ok
                    self.updatedAt = Date()
                    self.closeLoginIfDone()
                }
            case .failure(let e):
                self.state = .error(e.localizedDescription)
            }
            finish()
        }
    }

    private func parse(_ obj: [String: Any]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var list: [Window] = []
        let known: Set<String> = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        for (key, value) in obj {
            // Nur bekannte Limits – interne/experimentelle Einträge (Codenamen) ausblenden
            guard known.contains(key) else { continue }
            guard let w = value as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["resets_at"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            list.append(Window(key: key, label: Self.label(key), short: Self.short(key), utilization: u, resetsAt: resets))
        }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        list.sort { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
        if list != windows { windows = list }
    }

    static func label(_ key: String) -> String {
        switch key {
        case "five_hour": return "Aktuelle Sitzung (5 Std)"
        case "seven_day": return "Woche · alle Modelle"
        case "seven_day_opus": return "Woche · Opus"
        case "seven_day_sonnet": return "Woche · Sonnet"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func short(_ key: String) -> String {
        switch key {
        case "five_hour": return "5 Std"
        case "seven_day": return "Woche"
        case "seven_day_opus": return "Opus"
        case "seven_day_sonnet": return "Sonnet"
        default: return String(key.prefix(6))
        }
    }

    static func color(_ u: Double) -> Color {
        u >= 90 ? .red : (u >= 70 ? .orange : .claude)
    }

    static func resetText(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return tr("wird zurückgesetzt") }
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if h >= 24 {
            let f = DateFormatter()
            f.locale = Loc.locale
            f.dateFormat = "EEE HH:mm"
            return tr("zurück am ") + f.string(from: d)
        }
        return h > 0 ? tr("zurück in \(h) Std \(m) Min") : tr("zurück in \(m) Min")
    }

    // MARK: Anmelden

    func showLogin() {
        start()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = tr("Bei Claude anmelden – nur für die Nutzungsanzeige")
        w.isReleasedWhenClosed = false
        hostWindow.contentView = NSView()
        w.contentView = webView
        w.center()
        loginWindow = w
        NotificationCenter.default.addObserver(self, selector: #selector(loginClosed), name: NSWindow.willCloseNotification, object: w)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func closeLoginIfDone() {
        guard let w = loginWindow, state == .ok else { return }
        loginWindow = nil
        w.close()
    }

    @objc private func loginClosed(_ n: Notification) {
        loginWindow = nil
        hostWindow.contentView = webView
        pageReady = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }
}

// MARK: - Ansicht im Claude-Tab

struct ClaudeUsageStrip: View {
    @ObservedObject var usage = ClaudeUsage.shared

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.claude)
            switch usage.state {
            case .ok where !usage.windows.isEmpty:
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    HStack(spacing: 16) {
                        ForEach(usage.windows.prefix(3)) { w in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(w.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text("\(Int(w.utilization.rounded())) %")
                                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(ClaudeUsage.color(w.utilization))
                                }
                                ProgressBar(progress: w.utilization / 100, color: ClaudeUsage.color(w.utilization), height: 4)
                                Text(ClaudeUsage.resetText(w.resetsAt, now: ctx.date))
                                    .font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.4)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            case .loggedOut, .unknown:
                Text(tr("Nutzungslimit anzeigen")).font(.system(size: 11, weight: .semibold))
                Text(tr("einmal in der App bei claude.ai anmelden")).font(.system(size: 10.5)).foregroundStyle(Color.dim)
                Spacer(minLength: 0)
                PillButton(title: tr("Anmelden"), tint: Color.claude.opacity(0.9)) { ClaudeUsage.shared.showLogin() }
            case .loading:
                Text(tr("Nutzung wird geladen …")).font(.system(size: 11)).foregroundStyle(Color.dim)
                Spacer(minLength: 0)
            case .error(let e):
                Text(tr("Nutzung nicht verfügbar (\(e))")).font(.system(size: 10.5)).foregroundStyle(Color.dim).lineLimit(1)
                Spacer(minLength: 0)
                PillButton(title: tr("Erneut")) { ClaudeUsage.shared.refresh() }
            case .ok:
                Text(tr("Keine Limit-Daten")).font(.system(size: 11)).foregroundStyle(Color.dim)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
        .onAppear { ClaudeUsage.shared.refresh() }
    }
}

/// Kleine Ringe für den „Claude ist fertig“-Hinweis
struct UsageRings: View {
    let windows: [ClaudeUsage.Window]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(windows.prefix(2)) { w in
                VStack(spacing: 1) {
                    ZStack {
                        ProgressRing(progress: w.utilization / 100, color: ClaudeUsage.color(w.utilization), lineWidth: 3)
                        Text("\(Int(w.utilization.rounded()))").font(.system(size: 8.5, weight: .bold).monospacedDigit())
                    }
                    .frame(width: 24, height: 24)
                    Text(w.short).font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
    }
}
