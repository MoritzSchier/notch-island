import SwiftUI
import Combine

// MARK: - Datentypen

enum ActivityKind: String, Equatable, CaseIterable {
    case permission, ringing, call, timer, claude, media, meeting, download, camera, mic

    var tab: IslandTab {
        switch self {
        case .timer: return .timer
        case .claude, .permission: return .claude
        case .camera, .mic: return .widgets
        default: return .home
        }
    }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case home, shelf, mirror, timer, claude, web, colors, audio, widgets
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.full.fill"
        case .timer: return "timer"
        case .claude: return "sparkle"
        case .web: return "globe"
        case .colors: return "eyedropper.halffull"
        case .mirror: return "person.crop.square"
        case .audio: return "hifispeaker.fill"
        case .widgets: return "square.grid.2x2.fill"
        }
    }
    var title: String {
        switch self {
        case .home: return "Start"
        case .shelf: return "Ablage"
        case .timer: return "Timer"
        case .claude: return "Claude"
        case .web: return "Websites"
        case .colors: return "Farben"
        case .mirror: return "Spiegel"
        case .audio: return "Audio"
        case .widgets: return "Widgets"
        }
    }
}

enum WidgetTab: String, CaseIterable, Identifiable {
    case system = "System", clipboard = "Zwischenablage", note = "Notiz"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .system: return "gauge.with.dots.needle.33percent"
        case .clipboard: return "doc.on.clipboard"
        case .note: return "note.text"
        }
    }
}

struct ToastButton {
    let title: String
    let tint: Color
    let action: () -> Void
}

enum ToastTrailing {
    case none
    case text(String)
    case battery(Double, charging: Bool)
    case check
    case ring(Double)
    case usage([ClaudeUsage.Window])
}

/// Mitteilung im iPhone-Stil (Absender, erste Zeilen, gestapelt pro App)
struct MessageInfo {
    var bundleID: String?
    var appName: String
    var sender: String
    var text: String
    var count: Int = 1
    var date = Date()
}

struct Toast: Identifiable, Equatable {
    var id = UUID()
    var symbol: String = "bell.fill"
    var image: NSImage? = nil
    var tint: Color = .white
    var title: String
    var subtitle: String? = nil
    var trailing: ToastTrailing = .none
    var buttons: [ToastButton] = []
    var duration: TimeInterval = 3.5
    var onTap: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    /// Ergebnis-Datei: wird als ziehbares Dokument gezeigt
    var file: URL? = nil
    var message: MessageInfo? = nil

    var large: Bool { !buttons.isEmpty || file != nil }
    static func == (a: Toast, b: Toast) -> Bool {
        a.id == b.id && a.title == b.title && a.subtitle == b.subtitle && a.message?.count == b.message?.count
    }
}

enum HUDKind: Equatable {
    case volume(Double, muted: Bool)
    case brightness(Double)
}

enum Presentation: Equatable {
    case idle
    case compact(ActivityKind)
    case toast(Toast)
    case hud(HUDKind)
    case expanded
}

// MARK: - Modell

final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    @Published private(set) var presentation: Presentation = .idle
    @Published var tab: IslandTab = .home
    @Published var widgetTab: WidgetTab = .system
    @Published private(set) var isExpanded = false
    @Published private(set) var dropMode = false
    @Published private(set) var toast: Toast?
    @Published private(set) var hud: HUDKind?
    @Published private(set) var activities: [ActivityKind] = []
    /// Vom Nutzer per Stecknadel fixiert
    @Published var pinned = false
    /// Vorübergehendes Offenhalten (Teilen-Menü, Texteingabe …) – läuft spätestens nach `max` Sekunden ab
    @Published private(set) var holds: Set<String> = []
    var isHeld: Bool { pinned || !holds.isEmpty }

    func hold(_ reason: String, max: TimeInterval = 60) {
        holds.insert(reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + max) { [weak self] in self?.release(reason) }
    }

    func release(_ reason: String) {
        guard holds.remove(reason) != nil else { return }
        if !isHeld && !hovering && isExpanded && !dropMode { collapse() }
    }
    @Published private(set) var hovering = false
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    /// Breite des aktuellen Bildschirms – die Insel wird nie breiter (kleine Displays, große Skalierung)
    @Published var screenWidth: CGFloat = 1440

    weak var hostView: NSView?
    @Published var draggingTab: IslandTab?
    /// Dateien, die gerade auf die Notch gezogen werden (für passende Konvertier-Vorschläge)
    @Published var dragURLs: [URL] = []
    @Published private(set) var tabOrder: [IslandTab] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? []).compactMap(IslandTab.init(rawValue:))
        return saved + IslandTab.allCases.filter { !saved.contains($0) }
    }()

    /// Ausgeblendete Tabs (Einstellungen › Tabs). „Start“ ist immer da.
    @Published var hiddenTabs: Set<IslandTab> = Set((UserDefaults.standard.stringArray(forKey: "hiddenTabs") ?? []).compactMap(IslandTab.init(rawValue:))) {
        didSet {
            UserDefaults.standard.set(hiddenTabs.map(\.rawValue), forKey: "hiddenTabs")
            if hiddenTabs.contains(tab) { tab = .home }
        }
    }

    func isVisible(_ t: IslandTab) -> Bool { t == .home || !hiddenTabs.contains(t) }

    func setVisible(_ t: IslandTab, _ on: Bool) {
        guard t != .home else { return }
        if on { hiddenTabs.remove(t) } else { hiddenTabs.insert(t) }
    }

    var orderedTabs: [IslandTab] { tabOrder.filter(isVisible) }
    var orderedTabsAll: [IslandTab] { tabOrder }

    func moveTab(_ from: IslandTab, to: IslandTab) {
        guard let i = tabOrder.firstIndex(of: from), let j = tabOrder.firstIndex(of: to) else { return }
        var o = tabOrder
        o.remove(at: i)
        o.insert(from, at: j)
        tabOrder = o
        UserDefaults.standard.set(o.map(\.rawValue), forKey: "tabOrder")
    }

    func resetTabOrder() {
        tabOrder = IslandTab.allCases
        UserDefaults.standard.removeObject(forKey: "tabOrder")
    }
    var holdDrop = false

    private var bag = Set<AnyCancellable>()
    private var recomputePending = false
    private var toastWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?

    // MARK: Geometrie

    static let expandedHeight: CGFloat = 210

    func wing(_ k: ActivityKind) -> CGFloat {
        switch k {
        case .media: return 42
        case .timer: return 64
        case .claude: return 58
        case .call: return 74
        case .meeting: return 72
        case .download: return 56
        case .camera, .mic: return 44
        case .ringing, .permission: return 0
        }
    }

    func bodySize(_ p: Presentation) -> CGSize {
        let n = notchSize
        switch p {
        case .idle: return n
        case .compact(let k):
            if k == .ringing { return toastSize(large: true) }
            if k == .permission {
                let p = ClaudeService.shared.permission
                let head: CGFloat = p?.detail.isEmpty == false ? 72 : 56
                if p?.kind == .question {
                    let opts = p?.options ?? []
                    var rows = opts.filter { $0.role == .other }.reduce(CGFloat(0)) { $0 + ($1.detail.isEmpty && $1.label.count < 60 ? 31 : 41) }
                    if opts.contains(where: { $0.role != .other }) { rows += 34 }
                    return CGSize(width: max(notchSize.width + 360, 540), height: notchSize.height + head + rows + 14)
                }
                return CGSize(width: max(notchSize.width + 330, 520), height: notchSize.height + head + 36)
            }
            return CGSize(width: n.width + 2 * wing(k), height: n.height)
        case .toast(let t):
            if let m = t.message {
                var h: CGFloat = 64
                if m.text.count > 52 { h += 16 }
                if m.count > 1 { h += m.count > 2 ? 34 : 28 }
                return CGSize(width: max(notchSize.width + 300, 480), height: notchSize.height + h)
            }
            return toastSize(large: t.large)
        case .hud: return CGSize(width: n.width + 2 * 76, height: n.height)
        case .expanded:
            let s = expandedSize()
            return CGSize(width: min(s.width, screenWidth - 2 * 14 - 24), height: s.height)
        }
    }

    /// Jeder Tab bekommt nur so viel Platz, wie er braucht. "Start" ist bewusst klein.
    func expandedSize() -> CGSize {
        let n = notchSize
        let big = max(640, n.width + 420)
        if dropMode { return CGSize(width: big, height: Converter.options(for: dragURLs).isEmpty ? 196 : 270) }
        switch tab {
        case .home: return CGSize(width: n.width + 530, height: n.height + 104)
        case .shelf: return CGSize(width: big, height: 196)
        case .timer: return CGSize(width: big, height: 210)
        case .claude:
            let strip: CGFloat = Opt.on(Opt.claudeUsage) ? 0 : 48
            return ClaudeService.shared.current != nil ? CGSize(width: max(700, n.width + 480), height: 318 - strip) : CGSize(width: big, height: 282 - strip)
        case .web: return CGSize(width: big, height: WebFavorites.shared.rows > 1 ? 206 : 150)
        case .colors: return CGSize(width: max(680, n.width + 460), height: 214)
        case .audio: return CGSize(width: big, height: 206)
        case .mirror: return CGSize(width: big, height: 236)
        case .widgets: return CGSize(width: max(680, n.width + 460), height: 210)
        }
    }

    private func toastSize(large: Bool) -> CGSize {
        CGSize(width: max(notchSize.width + 210, 400), height: notchSize.height + (large ? 62 : 48))
    }

    func radii(_ p: Presentation) -> (top: CGFloat, bottom: CGFloat) {
        switch p {
        case .idle: return (6, 11)
        case .compact(let k): return (k == .ringing || k == .permission) ? (10, 26) : (6, 14)
        case .hud: return (6, 14)
        case .toast: return (10, 26)
        case .expanded: return (14, 32)
        }
    }

    func spring(for p: Presentation) -> Animation {
        switch p {
        case .expanded: return .spring(response: 0.44, dampingFraction: 0.74)
        case .idle: return .spring(response: 0.4, dampingFraction: 0.84)
        default: return .spring(response: 0.42, dampingFraction: 0.68)
        }
    }

    /// Rechteck der Insel (inkl. "Ohren") relativ zur Bildschirmoberkante, Breite zentriert.
    func outerSize(_ p: Presentation) -> CGSize {
        let s = bodySize(p), r = radii(p)
        return CGSize(width: s.width + 2 * r.top, height: s.height)
    }

    var secondary: ActivityKind? {
        guard case .compact(let k) = presentation, k != .ringing, k != .permission else { return nil }
        return activities.first { $0 != k && $0 != .ringing && $0 != .permission }
    }

    // MARK: Verknüpfung mit den Diensten

    func bind() {
        let pubs: [AnyPublisher<Void, Never>] = [
            MediaController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CallMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            TimerService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ClaudeService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CalendarService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            DownloadMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WebFavorites.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CameraMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(pubs)
            .sink { [weak self] in self?.setNeedsRecompute() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.setNeedsRecompute() }
            .store(in: &bag)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.recompute() }
        // Wächter: Offen bleibt die Insel nur, solange der Zeiger darauf ist, ein Sekunden-Timer läuft
        // (z. B. nach Konvertieren/Pipette) oder die Stecknadel gesetzt ist.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watchdog() }
        recompute()
    }

    func setNeedsRecompute() {
        guard !recomputePending else { return }
        recomputePending = true
        DispatchQueue.main.async { [weak self] in
            self?.recomputePending = false
            self?.recompute()
        }
    }

    func recompute() {
        var a: [ActivityKind] = []
        if ClaudeService.shared.permission != nil { a.append(.permission) }
        let calls = CallMonitor.shared
        if Prefs.on(Prefs.detectCalls) {
            if calls.ringing != nil { a.append(.ringing) }
            if calls.active != nil { a.append(.call) }
        }
        if ClaudeService.shared.current != nil && ClaudeService.shared.isPrimary { a.append(.claude) }
        if TimerService.shared.hasActive { a.append(.timer) }
        if ClaudeService.shared.current != nil && !ClaudeService.shared.isPrimary { a.append(.claude) }
        if Prefs.on(Prefs.showMedia), MediaController.shared.now?.isPlaying == true { a.append(.media) }
        if Prefs.on(Prefs.showCalendar), CalendarService.shared.soon != nil { a.append(.meeting) }
        if Prefs.on(Prefs.showDownloads), !DownloadMonitor.shared.active.isEmpty { a.append(.download) }
        if Prefs.on(Prefs.showPrivacy), calls.active == nil {
            if CameraMonitor.shared.inUse && !MirrorState.active { a.append(.camera) }
            else if !calls.micApps.isEmpty { a.append(.mic) }
        }
        if a != activities {
            let newRinging = (a.first == .ringing && activities.first != .ringing)
            activities = a
            if newRinging { haptic() }
            update()
        }
    }

    private func update() {
        let p: Presentation
        if activities.first == .permission && !dropMode { p = .compact(.permission) }
        else if let t = toast, !t.buttons.isEmpty, !dropMode { p = .toast(t) }   // z. B. Timer-Alarm mit „Stopp“ – auch über offenem Tab
        else if isExpanded || dropMode { p = .expanded }
        else if activities.first == .ringing { p = .compact(.ringing) }
        else if let t = toast { p = .toast(t) }
        else if let h = hud { p = .hud(h) }
        else if let a = activities.first { p = .compact(a) }
        else { p = .idle }
        if p != presentation { presentation = p }
    }

    // MARK: Toasts & HUD

    private var toastClickMonitor: Any?

    func show(_ t: Toast) {
        toastWork?.cancel()
        if toast?.id != t.id { toast?.onDismiss?() }
        DevBridge.log("Hinweis: \(t.title) · \(t.subtitle ?? "")")
        toast = t
        update()
        haptic()
        scheduleToastEnd(t, after: t.duration)
        if let m = toastClickMonitor { NSEvent.removeMonitor(m); toastClickMonitor = nil }
        if t.file != nil {
            // Klick irgendwo anders → Dokument ausblenden
            toastClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.toast?.id == t.id, !self.hovering else { return }
                    self.dismissToast(id: t.id)
                }
            }
        }
    }

    private func scheduleToastEnd(_ t: Toast, after: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.toast?.id == t.id else { return }
            // Dokument-Hinweis bleibt, solange die Maus darauf zeigt oder gerade gezogen wird
            if (t.file != nil || !t.buttons.isEmpty) && (self.hovering || NSEvent.pressedMouseButtons & 1 == 1) {
                self.scheduleToastEnd(t, after: 0.5)
                return
            }
            self.dismissToast(id: t.id)
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    func dismissToast(id: UUID? = nil) {
        guard let t = toast else { return }
        if let id, t.id != id { return }
        if let m = toastClickMonitor { NSEvent.removeMonitor(m); toastClickMonitor = nil }
        toast = nil
        t.onDismiss?()
        update()
    }

    func showHUD(_ h: HUDKind) {
        guard !isExpanded, toast == nil else { return }
        hud = h
        update()
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.hud = nil
            self?.update()
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    // MARK: Öffnen / Schließen

    func setHover(_ inside: Bool) {
        if ColorStore.shared.picking { return }   // während der Pipette nicht aufklappen
        guard inside != hovering else { return }
        hovering = inside
        hoverWork?.cancel()
        if inside {
            guard Prefs.on(Prefs.hoverToOpen), !isExpanded else { return }
            if case .compact(.ringing) = presentation { return }
            if case .compact(.permission) = presentation { return }
            // Dokument zum Ziehen oder Hinweis mit Knöpfen (z. B. „Timer abgelaufen · Stopp“): nicht aufklappen,
            // sonst verschwinden die Knöpfe unter dem Mauszeiger.
            if case .toast(let t) = presentation, t.file != nil || !t.buttons.isEmpty { return }
            let w = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Opt.double(Opt.hoverDelay)), execute: w)
        } else if isExpanded && !isHeld && !dropMode {
            let w = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
    }

    func expand(tab t: IslandTab? = nil) {
        if let t { tab = t } else if !isExpanded { tab = defaultTab() }
        if !isVisible(tab) { tab = .home }
        guard !isExpanded else { return }
        isExpanded = true
        update()
        haptic()
    }

    func collapse() {
        guard isExpanded else { return }
        if !dropMode { lastTab = tab; lastTabAt = Date() }
        isExpanded = false
        pinned = false
        holds = []
        hostView?.window?.resignKey()
        update()
    }

    func toggle() { isExpanded ? collapse() : expand() }

    private var awaySince: Date?
    private func watchdog() {
        guard isExpanded, !hovering, !isHeld, !dropMode, NSEvent.pressedMouseButtons & 1 == 0 else {
            awaySince = nil
            return
        }
        if awaySince == nil { awaySince = Date() }
        if let a = awaySince, Date().timeIntervalSince(a) > 0.6 {
            awaySince = nil
            collapse()
        }
    }

    // MARK: Offen halten (z. B. nach Konvertieren oder Pipette)

    private var holdMonitor: Any?
    private var holdTimer: Timer?

    /// Insel mindestens `seconds` offen lassen; ein Klick außerhalb schließt sie früher.
    /// Zeigt die Maus auf die Insel oder wird gerade gezogen, bleibt sie offen, bis man fertig ist.
    func holdOpen(seconds: TimeInterval) {
        releaseHold(collapse: false)
        holds.insert("timed")
        holdMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.releaseHold(collapse: true) }
        }
        holdTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.releaseHold(collapse: true)
        }
    }

    func releaseHold(collapse: Bool) {
        if let m = holdMonitor { NSEvent.removeMonitor(m) }
        holdMonitor = nil
        holdTimer?.invalidate()
        holdTimer = nil
        guard collapse else { return }
        // Während gerade etwas herausgezogen wird, nicht zuklappen – kurz später erneut prüfen
        if NSEvent.pressedMouseButtons & 1 == 1 {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.releaseHold(collapse: true)
            }
            return
        }
        holds.remove("timed")
        if !hovering && !isHeld { self.collapse() }
    }

    /// Zuletzt benutzter Tab – wird 5 Minuten lang wieder geöffnet, danach gilt wieder der Standard.
    private var lastTab: IslandTab?
    private var lastTabAt = Date.distantPast

    private func defaultTab() -> IslandTab {
        if ClaudeService.shared.isPrimary { return .claude }
        if let t = lastTab, Date().timeIntervalSince(lastTabAt) < 300 { return t }
        if let t = IslandTab(rawValue: UserDefaults.standard.string(forKey: Prefs.defaultTab) ?? "auto") { return t }
        switch activities.first {
        case .timer: return .timer
        case .claude: return .claude
        default: return .home
        }
    }

    func beginDrop() {
        guard !dropMode else { return }
        dropMode = true
        update()
        haptic()
    }

    func endDrop() {
        guard dropMode else { return }
        dropMode = false
        if hovering { isExpanded = true } else { isExpanded = false }
        update()
    }
}

enum MirrorState { static var active = false }
