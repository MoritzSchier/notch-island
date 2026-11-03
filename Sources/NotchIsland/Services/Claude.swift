import AppKit
import SwiftUI
import ApplicationServices

struct ClaudeTask: Identifiable, Equatable {
    enum Source: String { case desktop, mcp, code }
    enum State: String { case running, waiting, done, error }

    struct LogEntry: Equatable, Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    let id = UUID()
    var source: Source
    var title: String
    var detail: String? = nil
    var progress: Double? = nil
    var state: State
    var startedAt = Date()
    var finishedAt: Date? = nil
    var steps: [String] = []
    var currentStep: Int? = nil   // 0-basiert
    var log: [LogEntry] = []

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Fortschritt aus Schritten ableiten, falls Claude keinen Prozentwert schickt.
    var effectiveProgress: Double? {
        if let progress { return progress }
        if !steps.isEmpty, let c = currentStep { return Double(c) / Double(steps.count) }
        return nil
    }

    /// Geschätzte Restzeit (nur bei echtem Fortschritt).
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard let p = effectiveProgress, p > 0.05, p < 1 else { return nil }
        let e = now.timeIntervalSince(startedAt)
        return e * (1 - p) / p
    }

    /// Große Aufgabe? Dann darf Claude im Modus "Automatisch" zum Haupt-Tab werden.
    var isBig: Bool {
        source != .desktop || !steps.isEmpty || Date().timeIntervalSince(startedAt) > 45
    }
}

enum ClaudePrimaryMode: String, CaseIterable, Identifiable {
    case off, auto, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Aus"
        case .auto: return "Bei großen Aufgaben"
        case .always: return "Immer"
        }
    }
}

/// Zeigt, woran Claude gerade arbeitet.
/// Quellen: 1) Claude-Desktop-App (erkennt den „Stopp“-Knopf über die Bedienungshilfen),
///          2) MCP-Werkzeug `notch_status` (Claude meldet selbst Fortschritt),
///          3) Claude-Code-Hooks bzw. URL `notchisland://claude?...`.
final class ClaudeService: ObservableObject {
    static let shared = ClaudeService()

    @Published private(set) var current: ClaudeTask?
    @Published private(set) var history: [ClaudeTask] = []
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published var permission: PermissionPrompt?
    var permissionElements: [AXUIElement] = []
    var answeredKey = ""
    var answeredAt = Date.distantPast
    var answeredLabel = ""
    var retried = false
    var permissionIsDemo = false
    var lastButtonLabels: [String] = []

    private let queue = DispatchQueue(label: "notch.claude", qos: .utility)
    private var polling = false
    private var negatives = 0
    private var manualAX: Set<pid_t> = []
    private var timer: Timer?

    var primaryMode: ClaudePrimaryMode {
        get { ClaudePrimaryMode(rawValue: UserDefaults.standard.string(forKey: Prefs.claudePrimary) ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Prefs.claudePrimary); objectWillChange.send() }
    }

    /// Claude ist gerade der Haupt-Tab: Insel öffnet direkt mit Claude, Claude steht in der kompakten Insel vorn.
    var isPrimary: Bool {
        switch primaryMode {
        case .off: return false
        case .always: return true
        case .auto:
            guard let c = current else { return false }
            return c.isBig
        }
    }

    static let stopWords = ["stop response", "stop generating", "stop claude", "antwort stoppen", "antwort anhalten",
                            "generierung stoppen", "stoppen", "stopp", "stop"]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
        guard Prefs.on(Prefs.detectClaude), trusted, !polling else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Const.claudeBundle).first else {
            if current?.source == .desktop { finish(.done, silent: true) }
            if permission != nil && !permissionIsDemo { permission = nil }
            return
        }
        polling = true
        let pid = app.processIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            let r = self.detectGenerating(pid: pid)
            DispatchQueue.main.async {
                self.polling = false
                // Eine offene Rückfrage zählt als "wartet" – nicht als fertig
                self.applyDetection(r.generating || r.question != nil)
                self.applyPermission(r.permission ?? r.question)
            }
        }
    }

    private func applyDetection(_ generating: Bool) {
        if generating {
            negatives = 0
            if current == nil {
                current = ClaudeTask(source: .desktop, title: "Claude denkt nach …", state: .running)
            }
        } else if current?.source == .desktop {
            negatives += 1
            if negatives >= 2 { finish(.done) }
        }
    }

    /// Durchsucht die Fenster der Claude-App nach einem „Stopp“-Knopf (sichtbar, solange eine Antwort entsteht).
    private func detectGenerating(pid: pid_t) -> (generating: Bool, permission: PermissionScanner.Found?, question: PermissionScanner.Found?) {
        let app = AXUIElementCreateApplication(pid)
        if !manualAX.contains(pid) {
            // Electron-Apps legen ihren Bedienungshilfen-Baum erst offen, wenn man darum bittet.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAX.insert(pid)
        }
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let windows = AX.attr(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return (false, nil, nil) }
        var question: PermissionScanner.Found?
        var stack = windows
        var visited = 0
        var generating = false
        var permCandidates: [AXUIElement] = []
        var labels: [String] = []
        while let el = stack.popLast(), visited < 7000 {
            visited += 1
            let role = AX.string(el, kAXRoleAttribute as String)
            if question == nil, role == (kAXGroupRole as String), QuestionScanner.isCard(el) {
                question = QuestionScanner.parse(el)
                continue
            }
            if role == (kAXButtonRole as String) {
                let short = PermissionScanner.label(of: el)
                let label = [AX.string(el, kAXDescriptionAttribute as String),
                             AX.string(el, kAXTitleAttribute as String),
                             AX.string(el, kAXHelpAttribute as String)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if !short.isEmpty && labels.count < 300 { labels.append(short) }
                if !generating, !label.isEmpty, Self.stopWords.contains(where: { label.contains($0) }),
                   !label.contains("aufnahme"), !label.contains("recording"), !label.contains("diktat") {
                    generating = true
                }
                if PermissionScanner.role(for: short) != nil { permCandidates.append(el) }
                continue
            }
            stack.append(contentsOf: AX.children(el))
        }
        let found = permCandidates.isEmpty ? nil : PermissionScanner.build(from: permCandidates)
        DispatchQueue.main.async { self.lastButtonLabels = labels }
        return (generating, found, question)
    }

    func finish(_ state: ClaudeTask.State, silent: Bool = false, title: String? = nil) {
        guard var t = current else { return }
        t.state = state
        if !t.steps.isEmpty { t.currentStep = state == .done ? t.steps.count : t.currentStep }
        if state == .done { t.progress = 1 }
        t.finishedAt = Date()
        if let title { t.title = title }
        if t.source == .desktop { t.title = state == .error ? "Fehler" : "Antwort fertig" }
        current = nil
        negatives = 0
        history.insert(t, at: 0)
        if history.count > 12 { history.removeLast(history.count - 12) }
        guard !silent else { return }

        let elapsed = formatDuration((t.finishedAt ?? Date()).timeIntervalSince(t.startedAt))
        let front = AppInfo.frontmost == Const.claudeBundle
        let target = t.source == .code ? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? Const.claudeBundle) : Const.claudeBundle
        let failed = state == .error
        if !front && !failed && Opt.on(Opt.claudeSound) { NSSound(named: "Tink")?.play() }
        // Aktuelles Nutzungslimit gleich mit anzeigen (kurz neu laden, höchstens ~3 s warten)
        ClaudeUsage.shared.refresh {
            let usage = ClaudeUsage.shared.state == .ok ? ClaudeUsage.shared.windows : []
            var sub = t.source == .desktop ? "Antwort bereit · \(elapsed)" : (t.detail ?? "Fertig · \(elapsed)")
            if let s = ClaudeUsage.shared.session { sub += " · Limit \(Int(s.utilization.rounded())) %" }
            IslandModel.shared.show(Toast(
                symbol: failed ? "exclamationmark.triangle.fill" : "sparkle",
                tint: failed ? .red : .claude,
                title: failed ? "Claude: Problem aufgetreten" : (t.source == .desktop ? "Claude ist fertig" : t.title),
                subtitle: sub,
                trailing: failed ? .none : (usage.isEmpty ? .check : .usage(usage)),
                duration: front ? 3.5 : 7,
                onTap: { AppInfo.activate(target) }
            ))
        }
    }

    // MARK: Externe Meldungen (MCP, Hooks, URL)

    func handleExternal(_ d: [String: Any]) {
        let kind = d["kind"] as? String ?? "claude"
        switch kind {
        case "toast":
            IslandModel.shared.show(Toast(symbol: d["icon"] as? String ?? "sparkle", tint: .claude,
                                          title: d["title"] as? String ?? "Hinweis",
                                          subtitle: d["subtitle"] as? String, duration: 5))
        case "timer":
            if let m = Self.number(d["minutes"]) {
                TimerService.shared.start(seconds: m * 60, label: d["label"] as? String)
            }
        default:
            let state = ClaudeTask.State(rawValue: (d["state"] as? String ?? "running").lowercased()) ?? .running
            let src = ClaudeTask.Source(rawValue: d["source"] as? String ?? "mcp") ?? .mcp
            let title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let detail = (d["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let progress = Self.number(d["progress"]).map { $0 > 1 ? $0 / 100 : $0 }
            let steps = (d["steps"] as? [Any])?.compactMap { $0 as? String }
            var stepIndex = Self.number(d["step"]).map { Int($0) - 1 }
            if stepIndex == nil, let s = d["step"] as? String, let st = steps ?? current?.steps, let i = st.firstIndex(of: s) { stepIndex = i }
            switch state {
            case .running, .waiting:
                let wasPrimary = isPrimary
                if current == nil || current?.source == .desktop {
                    current = ClaudeTask(source: src, title: title ?? (src == .code ? "Claude Code" : "Claude arbeitet …"),
                                         detail: detail, progress: progress, state: state,
                                         startedAt: current?.startedAt ?? Date())
                } else {
                    if let title { current?.title = title }
                    if let detail { current?.detail = detail }
                    if let progress { current?.progress = progress }
                    current?.state = state
                }
                if let steps, !steps.isEmpty { current?.steps = steps; if current?.currentStep == nil { current?.currentStep = 0 } }
                if let stepIndex { current?.currentStep = max(0, stepIndex) }
                if let line = detail ?? (stepIndex.flatMap { i in current?.steps.indices.contains(i) == true ? current?.steps[i] : nil }),
                   current?.log.last?.text != line {
                    current?.log.append(.init(date: Date(), text: line))
                    if (current?.log.count ?? 0) > 30 { current?.log.removeFirst() }
                }
                // Wird Claude gerade zum Haupt-Tab und die Insel ist offen → dorthin wechseln
                if !wasPrimary && isPrimary && IslandModel.shared.isExpanded {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { IslandModel.shared.tab = .claude }
                }
                if state == .waiting {
                    IslandModel.shared.show(Toast(symbol: "hand.raised.fill", tint: .yellow, title: "Claude wartet auf dich",
                                                  subtitle: detail ?? title, duration: 6,
                                                  onTap: { AppInfo.activate(Const.claudeBundle) }))
                }
            case .done, .error:
                if current == nil {
                    current = ClaudeTask(source: src, title: title ?? "Claude", detail: detail, state: .running)
                }
                if let detail { current?.detail = detail }
                finish(state, title: title)
            }
        }
    }

    func handle(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var d: [String: Any] = [:]
        for q in c.queryItems ?? [] { d[q.name] = q.value ?? "" }
        let host = c.host ?? "claude"
        if host == "toast" || host == "timer" { d["kind"] = host }
        if d["source"] == nil { d["source"] = "code" }
        handleExternal(d)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    static func relative(_ d: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return "Fertig " + f.localizedString(for: d, relativeTo: now)
    }

    /// Kleine Vorschau zum Ausprobieren in den Einstellungen.
    func demo() {
        let steps = ["Quellen suchen", "12 Quellen lesen", "Zusammenfassen", "Bericht schreiben"]
        handleExternal(["state": "running", "title": "Recherche-Bericht", "detail": "Suche nach Quellen …", "steps": steps, "step": 1])
        for (i, step) in ["Lese Quelle 4 von 12 …", "Fasse Kernaussagen zusammen …", "Schreibe Bericht (3 Seiten) …"].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1) * 2.5) {
                self.handleExternal(["state": "running", "detail": step, "step": i + 2])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            self.handleExternal(["state": "done", "title": "Bericht fertig", "detail": "3 Seiten · 12 Quellen"])
        }
    }
}
