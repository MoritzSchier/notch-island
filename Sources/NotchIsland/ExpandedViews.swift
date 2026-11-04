import SwiftUI
import AppKit
import EventKit

struct ExpandedView: View {
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar().frame(height: model.notchSize.height)
            ZStack(alignment: .top) {
                if model.dropMode {
                    DropZoneView().transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    switch model.tab {
                    case .home: HomeView().transition(.opacity)
                    case .shelf: ShelfView().transition(.opacity)
                    case .timer: TimerTabView().transition(.opacity)
                    case .claude: ClaudeTabView().transition(.opacity)
                    case .web: WebTabView().transition(.opacity)
                    case .colors: ColorTabView().transition(.opacity)
                    case .mirror: MirrorTabView().transition(.opacity)
                    case .audio: AudioTabView().transition(.opacity)
                    case .widgets: WidgetsView().transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.18), value: model.tab)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.dropMode)
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var battery = BatteryMonitor.shared
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var shelf = ShelfStore.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(model.orderedTabs) { t in
                    TabButton(tab: t, dot: dot(for: t))
                }
            }
            .coordinateSpace(name: "tabbar")
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notchSize.width)
            HStack(spacing: 6) {
                if battery.hasBattery {
                    HStack(spacing: 5) {
                        Text(tr("\(Int((battery.level * 100).rounded())) %"))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.7))
                        BatteryIcon(level: battery.level, charging: battery.onAC && (battery.details?.chargingHW ?? battery.isCharging), width: 22)
                    }
                    .padding(.trailing, 4)
                }
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned, help: tr("Geöffnet lassen")) {
                    model.pinned.toggle()
                }
                SettingsPill {
                    (NSApp.delegate as? AppDelegate)?.openSettings()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    private func dot(for t: IslandTab) -> Color? {
        switch t {
        case .claude: return claude.current != nil ? .claude : nil
        case .timer: return TimerService.shared.hasActive ? .orange : nil
        case .shelf: return shelf.items.isEmpty ? nil : .blue
        default: return nil
        }
    }
}

struct TabButton: View {
    let tab: IslandTab
    var dot: Color?
    @ObservedObject var model = IslandModel.shared
    @State private var hover = false
    static let slot: CGFloat = 24   // Breite + Abstand eines Tabs

    var body: some View {
        let selected = model.tab == tab && !model.dropMode
        let dragging = model.draggingTab == tab
        Group {
            if tab == .claude {
                ClaudeLogo().frame(width: 12.5, height: 12.5)
            } else {
                Image(systemName: tab.icon).font(.system(size: 11.5, weight: .semibold))
            }
        }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(hover ? 0.85 : 0.48))
            .frame(width: 23, height: 22)
            .background(Capsule().fill(Color.white.opacity(dragging ? 0.25 : (selected ? 0.17 : (hover ? 0.07 : 0)))))
            .overlay(alignment: .topTrailing) {
                if let dot { Circle().fill(dot).frame(width: 5, height: 5).offset(x: -2, y: 2) }
            }
            .scaleEffect(dragging ? 1.15 : 1)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.tab = tab }
            }
            .onHover { hover = $0 }
            .help(tab.title + tr(" · zum Umsortieren ziehen"))
            // Eigenes Ziehen innerhalb der Insel (kein System-Drag) → löst kein Mission Control o. Ä. aus
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("tabbar"))
                    .onChanged { v in
                        if model.draggingTab == nil { model.draggingTab = tab; haptic() }
                        let tabs = model.orderedTabs
                        let target = max(0, min(tabs.count - 1, Int(v.location.x / Self.slot)))
                        if tabs[target] != tab {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.moveTab(tab, to: tabs[target]) }
                            haptic()
                        }
                    }
                    .onEnded { _ in model.draggingTab = nil }
            )
    }
}

// MARK: - Start

struct HomeView: View {
    @ObservedObject var calls = CallMonitor.shared
    @AppStorage(Opt.homeMedia) private var showMediaCard = true
    @AppStorage(Opt.homeVolume) private var showVolume = true
    @AppStorage(Opt.homeUpNext) private var showUpNext = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showMediaCard || showVolume {
                VStack(spacing: 9) {
                    if showMediaCard { MiniMediaCard() }
                    if showVolume { VolumeRow() }
                }
                .frame(maxWidth: .infinity)
            }
            if calls.active != nil || showUpNext {
                Group {
                    if calls.active != nil { CallCard() } else { UpNextCard() }
                }
                .frame(width: showMediaCard || showVolume ? 212 : nil)
                .frame(maxWidth: showMediaCard || showVolume ? nil : .infinity)
            }
            if !showMediaCard && !showVolume && !showUpNext && calls.active == nil {
                Text(tr("Alles ausgeblendet – Einstellungen › Tabs › Start")).font(.system(size: 12)).foregroundStyle(Color.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Kompakte Mediensteuerung für die kleine Startansicht.
struct MiniMediaCard: View {
    @ObservedObject var media = MediaController.shared

    var body: some View {
        HStack(spacing: 11) {
            if let np = media.now {
                ArtworkView(size: 58, radius: 13)
                    .overlay(alignment: .bottomTrailing) {
                        AppIconView(bundleID: np.appBundleID, size: 18)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: 5, y: 5)
                    }
                    .scaleEffect(np.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: np.isPlaying)
                    .onTapGesture { AppInfo.activate(np.appBundleID) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(np.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Text(np.artist.isEmpty ? np.sourceName : np.artist)
                                .font(.system(size: 11.5)).foregroundStyle(Color.dim).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        AudioBars(color: media.tint, playing: np.isPlaying, height: 11).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        MediaButton(symbol: "backward.fill", size: 12) { MediaController.shared.previous() }
                        MediaButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 17) { MediaController.shared.togglePlay() }
                        MediaButton(symbol: "forward.fill", size: 12) { MediaController.shared.next() }
                        if np.duration > 0 { MediaProgress(np: np, compact: true).padding(.leading, 4) }
                        else { Spacer(minLength: 0) }
                    }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.white.opacity(0.35))
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("Nichts wird abgespielt")).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        launcher(Const.spotify)
                        launcher(Const.music)
                        Button { NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!) } label: {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 16)).foregroundStyle(.red).frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableStyle())
                        .help("YouTube")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 58)
    }

    @ViewBuilder private func launcher(_ id: String) -> some View {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            Button { AppInfo.activate(id) } label: { AppIconView(bundleID: id, size: 22) }
                .buttonStyle(PressableStyle())
                .help(AppInfo.name(id))
        }
    }
}

/// "Als Nächstes": nächster Termin + nächste fällige Erinnerung.
struct UpNextCard: View {
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var sem = RemindersService.shared

    var body: some View {
        Card(padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                if !cal.authorized && sem.upcoming.isEmpty {
                    HStack {
                        Label("Kalender", systemImage: "calendar").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        PillButton(title: tr("Erlauben"), tint: .red.opacity(0.85)) { cal.requestAccess() }
                    }
                }
                if !sem.authorized && Prefs.on(Prefs.showReminders) && cal.next == nil {
                    HStack {
                        Label("Erinnerungen", systemImage: "checklist").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        PillButton(title: tr("Erlauben"), tint: .blue.opacity(0.85)) { sem.requestAccess() }
                    }
                }
                if let e = cal.next {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        row(color: Color(nsColor: e.calendar?.color ?? .systemRed), symbol: nil,
                            title: e.title ?? tr("Termin"), subtitle: CalendarService.describe(e, now: ctx.date),
                            join: CalendarService.joinURL(e))
                    }
                    .onTapGesture { CalendarService.openCalendarApp() }
                }
                if let d = sem.upcoming.first {
                    row(color: d.color, symbol: d.flagged ? "flag.fill" : "checklist",
                        title: d.title, subtitle: [d.list, RemindersService.relative(d.due)].compactMap { $0 }.joined(separator: " · "),
                        join: nil)
                        .onTapGesture { AppInfo.activate(RemindersService.appBundle) }
                }
                if cal.next == nil && sem.upcoming.isEmpty && cal.authorized {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 16)).foregroundStyle(.green)
                        Text(tr("Nichts Anstehendes")).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(height: 62, alignment: .top)
        }
    }

    private func row(color: Color, symbol: String?, title: String, subtitle: String, join: URL?) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(color) }
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Color.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let join {
                CircleButton(symbol: "video.fill", tint: .green, size: 22) { NSWorkspace.shared.open(join) }.help(tr("Beitreten"))
            }
        }
        .contentShape(Rectangle())
    }
}

struct MediaProgress: View {
    let np: NowPlaying
    var compact = false
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let dur = max(np.duration, 1)
            let pos = scrub ?? min(dur, np.position(at: ctx.date))
            HStack(spacing: 7) {
                if !compact { Text(formatDuration(pos)).frame(width: 34, alignment: .leading) }
                IslandSlider(value: Binding(get: { pos / dur }, set: { scrub = $0 * dur }), onEnded: {
                    if let s = scrub { MediaController.shared.seek(to: s) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scrub = nil }
                })
                Text("-" + formatDuration(max(0, dur - pos))).frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }
}

struct MediaControls: View {
    let np: NowPlaying
    var body: some View {
        HStack(spacing: 14) {
            MediaButton(symbol: "backward.fill") { MediaController.shared.previous() }
            MediaButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 21) { MediaController.shared.togglePlay() }
            MediaButton(symbol: "forward.fill") { MediaController.shared.next() }
            Spacer(minLength: 0)
            MediaButton(symbol: "arrow.up.forward.app", size: 12) { AppInfo.activate(np.appBundleID) }
                .help(tr("\(np.sourceName) öffnen"))
        }
    }
}

struct MediaButton: View {
    let symbol: String
    var size: CGFloat = 15
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)).frame(width: 30, height: 30))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct VolumeRow: View {
    @ObservedObject var vol = VolumeController.shared

    var body: some View {
        HStack(spacing: 9) {
            Button { vol.toggleMute() } label: {
                Image(systemName: vol.muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
            }
            .buttonStyle(PressableStyle())
            IslandSlider(value: Binding(get: { vol.muted ? 0 : vol.volume }, set: { vol.setVolume($0) }))
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.white.opacity(0.65))
    }
}

struct EmptyMediaView: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08))
                Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.white.opacity(0.35))
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Nichts wird abgespielt")).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    launcher("com.spotify.client")
                    launcher("com.apple.Music")
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!)
                    } label: {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 18)).foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(PressableStyle())
                    .help("YouTube")
                }
            }
        }
    }

    @ViewBuilder private func launcher(_ id: String) -> some View {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            Button { AppInfo.activate(id) } label: { AppIconView(bundleID: id, size: 28) }
                .buttonStyle(PressableStyle())
                .help(AppInfo.name(id))
        }
    }
}

struct NextEventCard: View {
    @ObservedObject var cal = CalendarService.shared

    var body: some View {
        Card {
            if !cal.authorized {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Kalender", systemImage: "calendar").font(.system(size: 12, weight: .semibold))
                    PillButton(title: tr("Zugriff erlauben"), tint: .red.opacity(0.85)) { cal.requestAccess() }
                }
            } else if let e = cal.next {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: e.calendar?.color ?? .systemRed))
                        .frame(width: 3.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title ?? tr("Termin")).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text(CalendarService.describe(e, now: ctx.date))
                                .font(.system(size: 11)).foregroundStyle(Color.dim).lineLimit(1)
                        }
                        if let loc = e.location, !loc.isEmpty {
                            Text(loc).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.4)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let url = CalendarService.joinURL(e) {
                        CircleButton(symbol: "video.fill", tint: .green, size: 28) { NSWorkspace.shared.open(url) }
                            .help(tr("Beitreten"))
                    }
                }
                .frame(height: 46)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 18)).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("Keine Termine")).font(.system(size: 12.5, weight: .semibold))
                        Text(tr("in den nächsten 36 Stunden")).font(.system(size: 11)).foregroundStyle(Color.dim)
                    }
                }
                .frame(height: 46)
            }
        }
        .onTapGesture { CalendarService.openCalendarApp() }
    }
}

struct CallCard: View {
    @ObservedObject var calls = CallMonitor.shared

    var body: some View {
        Card {
            HStack(spacing: 10) {
                AppIconView(bundleID: calls.active?.bundleID, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.humanize(calls.active?.name ?? tr("Anruf"))).font(.system(size: 12.5, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(calls.active?.start ?? ctx.date)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
                CircleButton(symbol: calls.micMuted ? "mic.slash.fill" : "mic.fill",
                             tint: calls.micMuted ? .orange : Color.white.opacity(0.15), size: 30) { calls.toggleMute() }
                    .help(calls.micMuted ? tr("Mikrofon an") : tr("Stummschalten"))
                CircleButton(symbol: "arrow.up.forward", size: 30) {
                    if let b = calls.active?.bundleID { AppInfo.activate(b) }
                }
                .help(tr("Zur App"))
            }
            .frame(height: 46)
        }
    }
}

struct QuickTiles: View {
    @ObservedObject var model = IslandModel.shared
    @ObservedObject var timers = TimerService.shared
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var shelf = ShelfStore.shared
    @ObservedObject var badges = DockBadgeMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile(symbol: "timer", tint: .orange, title: tr("Timer")) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        if let t = timers.timers.first {
                            Text(formatRemaining(t.remaining(at: ctx.date)))
                        } else if timers.swRunning {
                            Text(formatDuration(timers.swElapsed(at: ctx.date)))
                        } else {
                            Text(tr("Start"))
                        }
                    }
                } action: { model.tab = .timer }
                tile(symbol: "tray.full.fill", tint: .blue, title: tr("Ablage")) {
                    Text(shelf.items.isEmpty ? tr("Leer") : "\(shelf.items.count)")
                } action: { model.tab = .shelf }
                tile(symbol: "sparkle", tint: .claude, title: tr("Claude")) {
                    Text(claude.current != nil ? tr("Läuft") : (claude.history.isEmpty ? tr("Bereit") : tr("Fertig")))
                } action: { model.tab = .claude }
            }
            if !badges.badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(badges.badges.prefix(6)) { b in
                        Button { AppInfo.activate(b.bundleID) } label: {
                            AppIconView(bundleID: b.bundleID, size: 22)
                                .overlay(alignment: .topTrailing) {
                                    Text(b.label)
                                        .font(.system(size: 8.5, weight: .bold))
                                        .padding(.horizontal, 3.5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 6, y: -4)
                                }
                        }
                        .buttonStyle(PressableStyle())
                        .help(b.name)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func tile<V: View>(symbol: String, tint: Color, title: String, @ViewBuilder value: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                value().font(.system(size: 12.5, weight: .semibold).monospacedDigit()).lineLimit(1)
                Text(title).font(.system(size: 9.5)).foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.cardFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}


/// Gut sichtbarer Einstellungen-Knopf in der Kopfzeile (Symbol + Wort, hebt sich beim Zeigen hervor)
struct SettingsPill: View {
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // Passt der Text nicht hin (schmale Tabs), nur das Zahnrad zeigen
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    gear
                    Text(tr("Einstellungen")).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                gear
            }
            .foregroundStyle(hover ? Color.black : Color.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(hover ? Color.white : Color.white.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .help(tr("Einstellungen öffnen"))
    }

    private var gear: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 12, weight: .semibold))
            .rotationEffect(.degrees(hover ? 60 : 0))
    }
}
