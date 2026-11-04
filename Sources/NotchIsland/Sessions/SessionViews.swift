import SwiftUI
import AppKit

extension SessionStatus {
    /// Ampelfarben: grau bereit, gelb arbeitet, rot wartet auf dich, grün fertig.
    var color: Color {
        switch self {
        case .ready: return Color.white.opacity(0.35)
        case .working: return Color(red: 1.0, green: 0.78, blue: 0.2)
        case .blocked: return Color(red: 1.0, green: 0.33, blue: 0.3)
        case .done: return Color(red: 0.3, green: 0.85, blue: 0.45)
        }
    }
}

struct SessionDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(status.color).frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.25), value: status)
    }
}

/// Ein Punkt pro Session in der zugeklappten Notch (rechter Flügel).
struct SessionDots: View {
    static let maxDots = 8
    @ObservedObject var store = SessionStore.shared

    var body: some View {
        let list = store.sessions
        HStack(spacing: 4) {
            ForEach(list.prefix(Self.maxDots)) { s in
                SessionDot(status: store.displayStatus(s), size: 7)
            }
            if list.count > Self.maxDots {
                Text("+\(list.count - Self.maxDots)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.dim)
            }
        }
    }
}

// MARK: - Claude-Tab

struct SessionsPanel: View {
    @ObservedObject var store = SessionStore.shared
    @ObservedObject var claude = ClaudeService.shared

    static let rowHeight: CGFloat = 36
    static let spacing: CGFloat = 5
    /// Zeilen pro Spalte ohne Scrollen (zwei Spalten)
    static let visibleRows = 3

    static func height(for count: Int) -> CGFloat {
        let rows = CGFloat(min((count + 1) / 2, visibleRows))
        return 18 + rows * rowHeight + max(0, rows - 1) * spacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(text: tr("Claude Code · \(store.sessions.count) Sessions"))
                Spacer(minLength: 0)
                summary
                if store.sessions.contains(where: { store.displayStatus($0) == .done }) {
                    Button { store.acknowledgeAll() } label: {
                        Text(tr("Alle gesehen")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Self.spacing), GridItem(.flexible(), spacing: Self.spacing)],
                          spacing: Self.spacing) {
                    ForEach(store.sessions) { s in SessionRow(session: s) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            ForEach([SessionStatus.blocked, .working, .done], id: \.self) { st in
                let n = store.sessions.filter { store.displayStatus($0) == st }.count
                if n > 0 {
                    HStack(spacing: 3) {
                        SessionDot(status: st, size: 6)
                        Text("\(n)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Color.dim)
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    @ObservedObject var store = SessionStore.shared
    @ObservedObject var claude = ClaudeService.shared
    @State private var hover = false

    var body: some View {
        let status = store.displayStatus(session)
        HStack(spacing: 8) {
            SessionDot(status: status, size: 8)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(session.displayName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        .layoutPriority(1)
                    Text(statusText(status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(status == .ready ? Color.dim : status.color)
                        .lineLimit(1)
                }
                Text(secondLine(status))
                    .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if pending != nil {
                Text(pending?.kind == .question ? tr("Antworten") : tr("Freigeben"))
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.claude))
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(formatRuntime(session.runtime(now: ctx.date)))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Color.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: SessionsPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hover ? 0.12 : (status == .blocked ? 0.09 : 0.05))))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.open(session) }
        .help(session.activity ?? session.cwd)
        .contextMenu {
            Button(tr("Terminal nach vorn")) { claude.focusTerminal(sessionId: session.sessionId) }
            Button(tr("Ordner im Finder zeigen")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd) }
            Button(tr("Session-ID kopieren")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
            }
        }
    }

    private var pending: PermissionPrompt? {
        claude.externalPrompts.first { $0.sessionId == session.sessionId }
    }

    private func statusText(_ status: SessionStatus) -> String {
        if let p = pending { return p.kind == .question ? tr("Rückfrage") : tr("Wartet auf Freigabe") }
        switch status {
        case .ready: return tr("Bereit")
        case .working:
            let n = session.subagents ?? 0
            return n > 0 ? tr("Arbeitet · \(n) Sub") : tr("Arbeitet")
        case .blocked: return tr("Wartet auf dich")
        case .done:
            return ClaudeService.relative(session.updatedAt, now: Date())
        }
    }

    /// Unter dem Namen: worauf die Session gerade wartet bzw. was sie tut.
    private func secondLine(_ status: SessionStatus) -> String {
        if let p = pending { return p.title }
        if status == .blocked, let m = session.message, !m.isEmpty { return m }
        if status == .working, let t = session.tool { return t }
        return session.activity ?? session.project
    }
}
