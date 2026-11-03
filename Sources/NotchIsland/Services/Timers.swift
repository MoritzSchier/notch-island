import AppKit
import SwiftUI

struct IslandTimer: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var duration: TimeInterval
    var endDate: Date
    var pausedRemaining: TimeInterval? = nil

    var isPaused: Bool { pausedRemaining != nil }
    func remaining(at d: Date = Date()) -> TimeInterval { pausedRemaining ?? max(0, endDate.timeIntervalSince(d)) }
    func progress(at d: Date = Date()) -> Double { duration > 0 ? remaining(at: d) / duration : 0 }
}

final class TimerService: ObservableObject {
    static let shared = TimerService()

    @Published private(set) var timers: [IslandTimer] = []
    @Published private(set) var swStart: Date?
    @Published private(set) var swAccum: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = []

    private var tick: Timer?
    private var alarm: Timer?
    private var alarmCount = 0

    var swRunning: Bool { swStart != nil }
    var hasActive: Bool { !timers.isEmpty || swRunning }

    func swElapsed(at d: Date = Date()) -> TimeInterval {
        swAccum + (swStart.map { d.timeIntervalSince($0) } ?? 0)
    }

    // MARK: Timer

    func start(seconds: TimeInterval, label: String? = nil) {
        let l = label ?? Self.defaultLabel(seconds)
        timers.append(IslandTimer(label: l, duration: seconds, endDate: Date().addingTimeInterval(seconds)))
        timers.sort { $0.remaining() < $1.remaining() }
        ensureTick()
        haptic()
    }

    static func defaultLabel(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m >= 60 && m % 60 == 0 { return "\(m / 60)-Std-Timer" }
        return m > 0 ? "\(m)-Min-Timer" : tr("\(Int(s))-Sek-Timer")
    }

    func togglePause(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        if let r = timers[i].pausedRemaining {
            timers[i].endDate = Date().addingTimeInterval(r)
            timers[i].pausedRemaining = nil
        } else {
            timers[i].pausedRemaining = timers[i].remaining()
        }
    }

    func addMinute(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].duration += 60
        if let r = timers[i].pausedRemaining { timers[i].pausedRemaining = r + 60 }
        else { timers[i].endDate = timers[i].endDate.addingTimeInterval(60) }
    }

    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    private func ensureTick() {
        guard tick == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func check() {
        let now = Date()
        let done = timers.filter { !$0.isPaused && $0.endDate <= now }
        if !done.isEmpty {
            timers.removeAll { t in done.contains { $0.id == t.id } }
            for t in done { fire(t) }
        }
        if timers.isEmpty {
            tick?.invalidate()
            tick = nil
        }
    }

    private func fire(_ t: IslandTimer) {
        startAlarm()
        let label = t.label
        IslandModel.shared.show(Toast(
            symbol: "timer", tint: .orange, title: tr("Timer abgelaufen"), subtitle: label,
            buttons: [
                ToastButton(title: tr("+1 Min"), tint: Color.white.opacity(0.18)) { [weak self] in
                    self?.stopAlarm()
                    self?.start(seconds: 60, label: label)
                },
                ToastButton(title: tr("Stopp"), tint: .orange) { [weak self] in self?.stopAlarm() },
            ],
            duration: 30,
            onTap: { [weak self] in self?.stopAlarm() },
            onDismiss: { [weak self] in self?.stopAlarm() }
        ))
    }

    private func startAlarm() {
        alarm?.invalidate()
        alarmCount = 0
        let sound = UserDefaults.standard.string(forKey: Opt.timerSound) ?? "Glass"
        let maxRings = max(1, Int(Opt.double(Opt.timerAlarmSeconds) / 1.4))
        NSSound(named: sound)?.play()
        alarm = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.alarmCount += 1
            if self.alarmCount > maxRings { self.stopAlarm(); return }
            NSSound(named: sound)?.play()
        }
    }

    func stopAlarm() {
        alarm?.invalidate()
        alarm = nil
    }

    // MARK: Stoppuhr

    func swToggle() {
        if let s = swStart {
            swAccum += Date().timeIntervalSince(s)
            swStart = nil
        } else {
            swStart = Date()
        }
        haptic()
    }

    func swLapOrReset() {
        if swRunning {
            let total = swElapsed()
            let prev = laps.reduce(0, +)
            laps.insert(total - prev, at: 0)
        } else {
            swAccum = 0
            laps = []
        }
    }
}
