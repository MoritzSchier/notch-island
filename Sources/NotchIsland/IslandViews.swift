import SwiftUI
import AppKit

struct IslandRootView: View {
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var web = WebFavorites.shared

    var body: some View {
        let p = model.presentation
        let s = model.bodySize(p)
        let r = model.radii(p)
        let w = s.width + 2 * r.top
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: r.top, bottomRadius: r.bottom)
                    .fill(Color.black)
                IslandContent(presentation: p)
                    .padding(.horizontal, r.top)
                    .frame(width: w, height: s.height, alignment: .top)
                    .clipShape(NotchShape(topRadius: r.top, bottomRadius: r.bottom))
            }
            .frame(width: w, height: s.height)
            .overlay(alignment: .topTrailing) {
                SecondaryBubble()
                    .offset(x: model.notchSize.height + 8)
            }
            .shadow(color: .black.opacity(shadowOpacity(p)), radius: p == .expanded ? 24 : 10, y: p == .expanded ? 10 : 4)
            .opacity(!model.hasNotch && p == .idle ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.spring(for: p), value: p)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: s)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private func shadowOpacity(_ p: Presentation) -> Double {
        switch p {
        case .idle: return 0
        case .expanded: return 0.55
        case .toast: return 0.4
        default: return 0.2
        }
    }
}

struct IslandContent: View {
    let presentation: Presentation

    var body: some View {
        ZStack(alignment: .top) {
            switch presentation {
            case .idle:
                Color.clear
            case .compact(let k):
                CompactView(kind: k).id("c-" + k.rawValue).transition(.island)
            case .toast(let t):
                ToastView(toast: t).id(t.id).transition(.island)
            case .hud(let h):
                HUDView(kind: h).transition(.island)
            case .expanded:
                ExpandedView().transition(.island)
            }
        }
    }
}

// MARK: - Kompakt (Live-Aktivität)

struct CompactView: View {
    let kind: ActivityKind
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        if kind == .ringing {
            RingingView()
        } else if kind == .permission {
            PermissionView()
        } else {
            HStack(spacing: 0) {
                CompactLeading(kind: kind).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.notchSize.width)
                CompactTrailing(kind: kind).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 9)
            .frame(height: model.notchSize.height)
            .contentShape(Rectangle())
            .onTapGesture { model.expand(tab: kind.tab) }
        }
    }
}

struct CompactLeading: View {
    let kind: ActivityKind
    var small = false
    @ObservedObject var media = MediaController.shared
    @ObservedObject var calls = CallMonitor.shared

    var body: some View {
        Group {
            switch kind {
            case .media:
                ArtworkView(size: small ? 18 : 22, radius: small ? 9 : 6)
            case .call:
                HStack(spacing: 5) {
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                    if !small { AppIconView(bundleID: calls.active?.bundleID, size: 16) }
                }
            case .timer:
                Image(systemName: "timer").foregroundStyle(.orange)
            case .claude:
                ClaudeGlyph(size: small ? 12 : 14)
            case .meeting:
                Image(systemName: "calendar").foregroundStyle(.red)
            case .download:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .mic:
                Image(systemName: "mic.fill").foregroundStyle(.orange)
            case .camera:
                Image(systemName: "video.fill").foregroundStyle(.green)
            case .ringing:
                Image(systemName: "phone.arrow.down.left.fill").foregroundStyle(.green)
            case .permission:
                Image(systemName: "lock.shield.fill").foregroundStyle(Color.claude)
            }
        }
        .font(.system(size: small ? 11 : 13, weight: .semibold))
    }
}

struct CompactTrailing: View {
    let kind: ActivityKind
    @ObservedObject var media = MediaController.shared
    @ObservedObject var calls = CallMonitor.shared
    @ObservedObject var timers = TimerService.shared
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var downloads = DownloadMonitor.shared

    var body: some View {
        Group {
            switch kind {
            case .media:
                AudioBars(color: media.tint, playing: media.now?.isPlaying ?? false)
            case .call:
                HStack(spacing: 4) {
                    if calls.micMuted { Image(systemName: "mic.slash.fill").foregroundStyle(.orange) }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(calls.active?.start ?? ctx.date)))
                    }
                    .foregroundStyle(.green)
                }
            case .timer:
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    if let t = timers.timers.first {
                        Text(formatRemaining(t.remaining(at: ctx.date)))
                            .foregroundStyle(t.isPaused ? Color.orange.opacity(0.6) : .orange)
                    } else {
                        Text(formatDuration(timers.swElapsed(at: ctx.date))).foregroundStyle(.orange)
                    }
                }
            case .claude:
                if let p = claude.current?.effectiveProgress {
                    ProgressRing(progress: p, color: .claude, lineWidth: 2.5).frame(width: 15, height: 15)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(claude.current?.startedAt ?? ctx.date)))
                            .foregroundStyle(Color.claude)
                    }
                }
            case .meeting:
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(cal.soon.map { CalendarService.shortCountdown(to: $0.startDate, now: ctx.date) } ?? "")
                        .foregroundStyle(.red)
                }
            case .download:
                if let p = downloads.active.first?.progress {
                    ProgressRing(progress: p, color: .blue, lineWidth: 2.5).frame(width: 15, height: 15)
                } else {
                    Text(formatBytes(downloads.active.first?.bytes ?? 0)).foregroundStyle(.blue).font(.system(size: 11, weight: .semibold))
                }
            case .mic:
                AppIconView(bundleID: calls.micApps.first, size: 16)
            case .camera:
                Circle().fill(Color.green).frame(width: 7, height: 7)
            case .ringing, .permission:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .lineLimit(1)
    }
}

struct ArtworkView: View {
    var size: CGFloat
    var radius: CGFloat
    @ObservedObject var media = MediaController.shared

    var body: some View {
        ZStack {
            if let img = media.artwork {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SecondaryBubble: View {
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        let d = model.notchSize.height
        ZStack {
            if let k = model.secondary {
                Circle()
                    .fill(Color.black)
                    .overlay(CompactLeading(kind: k, small: true))
                    .frame(width: d, height: d)
                    .id(k.rawValue)
                    .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
                    .onTapGesture { model.expand(tab: k.tab) }
            }
        }
        .frame(width: d, height: d)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: model.secondary)
    }
}

// MARK: - Mitteilung im iPhone-Stil

struct MessageToastView: View {
    let toast: Toast
    let message: MessageInfo
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height - 2)
            ZStack(alignment: .top) {
                // Stapel: weitere Mitteilungen derselben App schauen unten heraus
                if message.count > 2 {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05))
                        .padding(.horizontal, 26).offset(y: 13)
                }
                if message.count > 1 {
                    RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.08))
                        .padding(.horizontal, 13).offset(y: 6.5)
                }
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.13))
                HStack(alignment: .top, spacing: 11) {
                    ZStack(alignment: .bottomTrailing) {
                        if let id = message.bundleID, let img = AppInfo.icon(id) {
                            Image(nsImage: img).resizable().interpolation(.high).frame(width: 36, height: 36)
                        } else {
                            Image(systemName: "bell.fill").font(.system(size: 16)).foregroundStyle(.white)
                                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 9).fill(Color.red))
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(message.sender).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text(Self.ago(message.date, now: ctx.date)).font(.system(size: 10.5)).foregroundStyle(Color.dim)
                            }
                        }
                        Text(message.text.isEmpty ? message.appName : message.text)
                            .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if message.count > 1 {
                            Text("\(message.appName) · \(message.count) Mitteilungen")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.dim)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, message.count > 2 ? 22 : (message.count > 1 ? 16 : 9))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let a = toast.onTap { a() }
            model.dismissToast(id: toast.id)
        }
    }

    static func ago(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        return s < 60 ? "jetzt" : "vor \(s / 60) Min"
    }
}

// MARK: - Anruf klingelt

struct RingingView: View {
    @ObservedObject var calls = CallMonitor.shared
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height - 4)
            HStack(spacing: 12) {
                AppIconView(bundleID: calls.ringing?.bundleID, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.humanize(calls.ringing?.name ?? "Anruf")).font(.system(size: 14, weight: .semibold))
                    Text("Eingehender Anruf").font(.system(size: 12)).foregroundStyle(Color.dim)
                }
                Spacer(minLength: 8)
                CircleButton(symbol: "xmark", tint: .red, size: 38) { calls.dismissRinging() }
                CircleButton(symbol: "phone.fill", tint: .green, size: 38) { calls.answer() }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Hinweis (Toast)

struct ToastView: View {
    let toast: Toast
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        if let m = toast.message {
            MessageToastView(toast: toast, message: m)
        } else {
            plain
        }
    }

    private var plain: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height - 4)
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.humanize(toast.title)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if let s = toast.subtitle {
                        Text(AppInfo.humanize(s)).font(.system(size: 12)).foregroundStyle(Color.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                ForEach(Array(toast.buttons.enumerated()), id: \.offset) { _, b in
                    PillButton(title: b.title, tint: b.tint) {
                        b.action()
                        model.dismissToast(id: toast.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let a = toast.onTap { a(); model.dismissToast(id: toast.id) } else { model.expand() }
        }
        .onDrag {
            guard let f = toast.file else { return NSItemProvider() }
            return FileDrag.provider(f)
        }
    }

    @ViewBuilder private var icon: some View {
        if let f = toast.file {
            FileThumb(url: f)
        } else if let img = toast.image {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
        } else {
            Image(systemName: toast.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(toast.tint.opacity(0.18)))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch toast.trailing {
        case .none:
            EmptyView()
        case .text(let s):
            Text(s).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(toast.tint)
        case .battery(let level, let charging):
            HStack(spacing: 6) {
                Text("\(Int((level * 100).rounded())) %")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(charging ? .green : (level <= 0.2 ? .red : .white))
                BatteryIcon(level: level, charging: charging, width: 28)
            }
        case .check:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: toast.id)
        case .ring(let v):
            ProgressRing(progress: v, color: toast.tint, lineWidth: 3).frame(width: 22, height: 22)
        case .usage(let w):
            UsageRings(windows: w)
        }
    }
}

struct FileThumb: View {
    let url: URL
    @State private var thumb: NSImage?
    var body: some View {
        Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .task(id: url) { thumb = await Thumbnailer.thumbnail(for: url) }
    }
}

// MARK: - Lautstärke / Helligkeit

struct HUDView: View {
    let kind: HUDKind
    @ObservedObject var model = IslandModel.shared

    private var value: Double {
        switch kind {
        case .volume(let v, let m): return m ? 0 : v
        case .brightness(let v): return v
        }
    }

    private var symbol: String {
        switch kind {
        case .volume(let v, let m):
            if m || v < 0.01 { return "speaker.slash.fill" }
            if v < 0.34 { return "speaker.wave.1.fill" }
            if v < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness(let v):
            return v < 0.4 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notchSize.width)
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white).frame(width: 46 * max(0, min(1, value)))
                }
                .frame(width: 46, height: 5)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .frame(height: model.notchSize.height)
    }
}
