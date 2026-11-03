import SwiftUI
import AppKit

struct ClaudeTabView: View {
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var sessions = SessionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !sessions.sessions.isEmpty {
                SessionsPanel().frame(maxHeight: .infinity)
            } else if let t = claude.current {
                HStack(alignment: .top, spacing: 14) {
                    ClaudeTaskCard(task: t).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ClaudeStepsView(task: t).frame(width: 250)
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ClaudeIdleCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                    ClaudeHistoryView().frame(width: 230)
                }
                .frame(maxHeight: .infinity)
            }
            if Opt.on(Opt.claudeUsage) { ClaudeUsageStrip() }
            ClaudeFooter()
        }
    }
}

// MARK: - Laufende Aufgabe

struct ClaudeTaskCard: View {
    let task: ClaudeTask

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    ZStack {
                        if let p = task.effectiveProgress {
                            ProgressRing(progress: p, color: .claude, lineWidth: 3.5).frame(width: 38, height: 38)
                        } else {
                            Circle().stroke(Color.claude.opacity(0.25), lineWidth: 3.5).frame(width: 38, height: 38)
                        }
                        ClaudeGlyph(size: 15, spinning: task.state == .running)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(task.state == .waiting ? tr("Wartet auf deine Antwort") : sourceText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(task.state == .waiting ? Color.yellow : Color.claude)
                    }
                    Spacer(minLength: 0)
                }
                if let d = task.detail {
                    Text(d)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: d)
                }
                Spacer(minLength: 0)
                if let p = task.effectiveProgress {
                    ProgressBar(progress: p, color: .claude, height: 7)
                } else {
                    IndeterminateBar(color: .claude, height: 7)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 14) {
                        stat(tr("Dauer"), formatDuration(ctx.date.timeIntervalSince(task.startedAt)))
                        if let p = task.effectiveProgress { stat(tr("Fortschritt"), tr("\(Int((p * 100).rounded())) %")) }
                        if !task.steps.isEmpty, let c = task.currentStep {
                            stat(tr("Schritt"), "\(min(c + 1, task.steps.count)) / \(task.steps.count)")
                        }
                        if let r = task.remaining(at: ctx.date) { stat(tr("Noch ca."), formatDuration(r)) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 9.5)).foregroundStyle(Color.white.opacity(0.45))
        }
    }

    private var sourceText: String {
        switch task.source {
        case .desktop: return tr("Schreibt eine Antwort …")
        case .mcp: return tr("Arbeitet an deinem Auftrag …")
        case .code: return tr("Claude Code arbeitet …")
        }
    }
}

/// Schritte (falls Claude welche gemeldet hat) oder das Protokoll der letzten Meldungen.
struct ClaudeStepsView: View {
    let task: ClaudeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: task.steps.isEmpty ? tr("Verlauf") : tr("Schritte"))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        if task.steps.isEmpty {
                            if task.log.isEmpty {
                                Text(tr("Sobald Claude Zwischenstände meldet, erscheinen sie hier."))
                                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                            }
                            ForEach(task.log) { e in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(e.date, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 9.5).monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.35))
                                    Text(e.text).font(.system(size: 11.5)).lineLimit(2)
                                        .foregroundStyle(e.id == task.log.last?.id ? Color.white : Color.white.opacity(0.6))
                                }
                                .id(e.id)
                            }
                        } else {
                            ForEach(Array(task.steps.enumerated()), id: \.offset) { i, step in
                                stepRow(i, step).id(i)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: task.log.count) { _, _ in
                    if let last = task.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: task.currentStep) { _, c in
                    if let c { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                }
            }
        }
    }

    @ViewBuilder private func stepRow(_ i: Int, _ step: String) -> some View {
        let current = task.currentStep ?? 0
        let done = i < current
        let active = i == current && task.state != .done
        HStack(spacing: 8) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active {
                    ProgressView().controlSize(.mini).tint(Color.claude)
                } else {
                    Image(systemName: "circle").foregroundStyle(Color.white.opacity(0.3))
                }
            }
            .font(.system(size: 13))
            .frame(width: 16, height: 16)
            Text(step)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(done ? Color.white.opacity(0.55) : (active ? Color.white : Color.white.opacity(0.45)))
                .strikethrough(false)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Color.claude.opacity(0.16) : .clear))
    }
}

// MARK: - Ruhezustand

struct ClaudeIdleCard: View {
    @ObservedObject var claude = ClaudeService.shared

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let last = claude.history.first {
                    HStack(spacing: 10) {
                        Image(systemName: last.state == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 24)).foregroundStyle(last.state == .error ? .red : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(last.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text(ClaudeService.relative(last.finishedAt ?? last.startedAt, now: ctx.date) + tr(" · Dauer ") + formatDuration(last.elapsed))
                                    .font(.system(size: 11.5)).foregroundStyle(Color.dim)
                            }
                        }
                    }
                    if let d = last.detail { Text(d).font(.system(size: 12)).foregroundStyle(Color.dim).lineLimit(2) }
                } else {
                    HStack(spacing: 10) {
                        ClaudeGlyph(size: 22, spinning: false)
                        Text(tr("Claude ist bereit")).font(.system(size: 14, weight: .semibold))
                    }
                    Text(tr("Gib Claude einen Auftrag – hier siehst du dann Schritte, Fortschritt und geschätzte Restzeit."))
                        .font(.system(size: 12)).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    PillButton(title: tr("Claude öffnen"), symbol: "arrow.up.forward.app", tint: Color.claude.opacity(0.9)) {
                        AppInfo.activate(Const.claudeBundle)
                    }
                    PillButton(title: tr("Vorschau"), symbol: "play.fill") { claude.demo() }
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct ClaudeHistoryView: View {
    @ObservedObject var claude = ClaudeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: tr("Erledigt"))
            if claude.history.isEmpty {
                Text(tr("Noch keine Aufgaben")).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.4))
            }
            ForEach(claude.history.prefix(4)) { t in
                HStack(spacing: 7) {
                    Image(systemName: t.state == .error ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(t.state == .error ? .red : .green)
                    Text(t.title).font(.system(size: 11.5)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(formatDuration(t.elapsed))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.white.opacity(0.4))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Schalter: Claude als Haupt-Tab
struct ClaudeFooter: View {
    @ObservedObject var claude = ClaudeService.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color.claude)
            Text(tr("Claude als Haupt-Tab")).font(.system(size: 11, weight: .semibold))
            HStack(spacing: 2) {
                ForEach(ClaudePrimaryMode.allCases) { m in
                    let sel = claude.primaryMode == m
                    Button { withAnimation(.easeInOut(duration: 0.15)) { claude.primaryMode = m } } label: {
                        Text(m.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(sel ? Color.black : Color.white.opacity(0.7))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(sel ? Color.claude : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            Spacer(minLength: 0)
            if !claude.axTrusted {
                Button { AX.requestTrust() } label: {
                    Label("Auto-Erkennung aktivieren", systemImage: "hand.raised.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.claude)
                }
                .buttonStyle(.plain)
                .help(tr("Bedienungshilfen erlauben, damit die Notch erkennt, wann Claude antwortet."))
            }
        }
    }
}
