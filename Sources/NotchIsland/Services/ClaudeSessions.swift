import AppKit
import SwiftUI
import ApplicationServices

/// Ein Claude-Desktop-Fenster mit laufender oder kürzlich fertiger Antwort.
/// Claude-Code-Sitzungen laufen separat über `SessionStore` (Ampel, Freigaben, Rückfragen).
struct DesktopSession: Identifiable, Equatable {
    enum State: Int { case waiting = 0, running = 1, done = 2 }

    let id: String
    var name: String
    var state: State
    var activity: String?
    var startedAt = Date()
    var updatedAt = Date()
    var window: AXUIElement?

    static func == (a: DesktopSession, b: DesktopSession) -> Bool {
        a.id == b.id && a.state == b.state && a.activity == b.activity && a.name == b.name && a.updatedAt == b.updatedAt
    }
}

extension ClaudeService {
    /// Sitzungen für die Übersicht: wartende zuerst, dann laufende, dann kürzlich fertige
    var visibleSessions: [DesktopSession] {
        let now = Date()
        return desktopSessions
            .filter { $0.state != .done || now.timeIntervalSince($0.updatedAt) < 600 }
            .sorted { ($0.state.rawValue, -$0.updatedAt.timeIntervalSince1970) < ($1.state.rawValue, -$1.updatedAt.timeIntervalSince1970) }
    }

    var activeSessionCount: Int { desktopSessions.filter { $0.state != .done }.count }

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
            let existing = desktopSessions.first { $0.id == id }
            guard w.generating || w.waiting || existing != nil else { continue }
            var s = existing ?? DesktopSession(id: id, name: name, state: .running)
            let newState: DesktopSession.State = w.waiting ? .waiting : (w.generating ? .running : .done)
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
        for i in desktopSessions.indices where !seen.contains(desktopSessions[i].id) && desktopSessions[i].state != .done {
            desktopSessions[i].state = .done
            desktopSessions[i].updatedAt = Date()
        }
    }

    private func upsert(_ s: DesktopSession) {
        if let i = desktopSessions.firstIndex(where: { $0.id == s.id }) {
            if desktopSessions[i] != s || desktopSessions[i].window == nil { desktopSessions[i] = s }
        } else {
            desktopSessions.append(s)
        }
        // alte, fertige Sitzungen aufräumen
        let now = Date()
        desktopSessions.removeAll { $0.state == .done && now.timeIntervalSince($0.updatedAt) > 1800 }
    }

    /// Zur Sitzung springen: Claude-Fenster nach vorn holen
    func focus(_ s: DesktopSession) {
        if let w = s.window {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AppInfo.activate(Const.claudeBundle)
    }
}

// MARK: - Übersicht im Claude-Tab

struct DesktopSessionsView: View {
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
                        DesktopSessionRow(session: s)
                            .onTapGesture { claude.focus(s) }
                    }
                }
            }
        }
    }
}

struct DesktopSessionRow: View {
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: "bubble.left.fill")
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
