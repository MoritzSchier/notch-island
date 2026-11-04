import AppKit
import SwiftUI
import ApplicationServices

/// Eine laufende Claude-Sitzung (Claude-Code-Terminal oder Claude-Desktop-Fenster).
/// Alle zusammen ergeben die Übersicht „Was machen meine Agenten gerade?“.
struct ClaudeSession: Identifiable, Equatable {
    enum Source { case code, desktop }
    enum State: Int { case waiting = 0, running = 1, done = 2 }

    let id: String
    var source: Source
    var name: String
    var state: State
    var activity: String?
    var startedAt = Date()
    var updatedAt = Date()
    /// Terminal-App (aus TERM_PROGRAM), um beim Klick dorthin zu springen
    var terminalBundle: String?
    var window: AXUIElement?

    static func == (a: ClaudeSession, b: ClaudeSession) -> Bool {
        a.id == b.id && a.state == b.state && a.activity == b.activity && a.name == b.name && a.updatedAt == b.updatedAt
    }

    static func terminalBundle(for termProgram: String?) -> String? {
        switch termProgram?.lowercased() ?? "" {
        case "apple_terminal": return "com.apple.Terminal"
        case "iterm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "warpterminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        case "wezterm": return "com.github.wez.wezterm"
        case "tabby": return "org.tabby"
        case "": return nil
        default: return nil
        }
    }
}

extension ClaudeService {
    /// Sitzungen für die Übersicht: wartende zuerst, dann laufende, dann kürzlich fertige
    var visibleSessions: [ClaudeSession] {
        let now = Date()
        return sessions
            .filter { $0.state != .done || now.timeIntervalSince($0.updatedAt) < 600 }
            .sorted { ($0.state.rawValue, -$0.updatedAt.timeIntervalSince1970) < ($1.state.rawValue, -$1.updatedAt.timeIntervalSince1970) }
    }

    var activeSessionCount: Int { sessions.filter { $0.state != .done }.count }

    // MARK: Claude Code (Hooks)

    func updateCodeSession(_ d: [String: Any]) {
        guard let sid = d["session"] as? String, !sid.isEmpty else { return }
        let state = (d["state"] as? String ?? "running").lowercased()
        let id = "code:" + sid
        if state == "end" {
            sessions.removeAll { $0.id == id }
            return
        }
        var s = sessions.first { $0.id == id }
            ?? ClaudeSession(id: id, source: .code, name: d["project"] as? String ?? "Claude Code", state: .running)
        if let p = d["project"] as? String, !p.isEmpty { s.name = p }
        if let t = d["term"] as? String { s.terminalBundle = ClaudeSession.terminalBundle(for: t) ?? s.terminalBundle }
        switch state {
        case "waiting", "permission": s.state = .waiting
        case "done", "error": s.state = .done
        default:
            if s.state == .done { s.startedAt = Date() }
            s.state = .running
        }
        if let a = d["activity"] as? String { s.activity = a }
        else if let det = d["detail"] as? String, !det.isEmpty { s.activity = det }
        if state == "done" { s.activity = tr("Fertig") }
        s.updatedAt = Date()
        upsert(s)
    }

    // MARK: Claude Desktop (Fenster)

    struct DesktopWindowState {
        let window: AXUIElement
        let title: String
        let generating: Bool
        let waiting: Bool
    }

    func updateDesktopSessions(_ wins: [DesktopWindowState]) {
        var seen = Set<String>()
        for w in wins {
            let name = (w.title.isEmpty || w.title == "Claude") ? "Claude" : w.title
            let id = "desktop:" + name
            seen.insert(id)
            let existing = sessions.first { $0.id == id }
            guard w.generating || w.waiting || existing != nil else { continue }
            var s = existing ?? ClaudeSession(id: id, source: .desktop, name: name, state: .running)
            let newState: ClaudeSession.State = w.waiting ? .waiting : (w.generating ? .running : .done)
            if s.state == .done && newState != .done { s.startedAt = Date() }
            if newState != s.state || s.window == nil {
                s.state = newState
                s.activity = newState == .waiting ? tr("Wartet auf deine Antwort") : (newState == .running ? tr("Schreibt eine Antwort …") : tr("Fertig"))
                s.updatedAt = Date()
            }
            s.window = w.window
            upsert(s)
        }
        // Fenster geschlossen → Sitzung als fertig markieren
        for i in sessions.indices where sessions[i].source == .desktop && !seen.contains(sessions[i].id) && sessions[i].state != .done {
            sessions[i].state = .done
            sessions[i].updatedAt = Date()
        }
    }

    private func upsert(_ s: ClaudeSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            if sessions[i] != s || sessions[i].window == nil { sessions[i] = s }
        } else {
            sessions.append(s)
        }
        // alte, fertige Sitzungen aufräumen
        let now = Date()
        sessions.removeAll { $0.state == .done && now.timeIntervalSince($0.updatedAt) > 1800 }
    }

    /// Zur Sitzung springen: Claude-Fenster nach vorn bzw. das Terminal öffnen
    func focus(_ s: ClaudeSession) {
        switch s.source {
        case .desktop:
            if let w = s.window {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            AppInfo.activate(Const.claudeBundle)
        case .code:
            AppInfo.activate(s.terminalBundle ?? "com.apple.Terminal")
        }
    }
}

// MARK: - Übersicht im Claude-Tab

struct ClaudeSessionsView: View {
    @ObservedObject var claude = ClaudeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: tr("Sitzungen"))
                Spacer()
                let n = claude.activeSessionCount
                if n > 0 {
                    Text(tr("\(n) aktiv")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.claude)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(claude.visibleSessions) { s in
                        SessionRow(session: s)
                            .onTapGesture { claude.focus(s) }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: session.source == .code ? "terminal.fill" : "bubble.left.fill")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(session.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(session.state == .done ? stateText : formatDuration(ctx.date.timeIntervalSince(session.startedAt)))
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(color)
                    }
                }
                Text(session.activity ?? stateText)
                    .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(session.state == .waiting ? Color.yellow.opacity(0.12) : Color.white.opacity(0.05)))
        .contentShape(Rectangle())
        .help(tr("Klicken, um zu dieser Sitzung zu springen"))
    }

    private var color: Color {
        switch session.state {
        case .waiting: return .yellow
        case .running: return .claude
        case .done: return .green
        }
    }

    private var stateText: String {
        switch session.state {
        case .waiting: return tr("wartet")
        case .running: return tr("läuft")
        case .done: return tr("fertig")
        }
    }
}
