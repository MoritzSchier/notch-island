import SwiftUI

struct TimerTabView: View {
    @ObservedObject var ts = TimerService.shared
    @State private var customMinutes = 10

    @AppStorage(Opt.timerPresets) private var presetsRaw = "1,3,5,10,15,25,45,60"
    private var presets: [Int] { _ = presetsRaw; return Opt.timerPresetMinutes }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                if ts.timers.isEmpty {
                    SectionLabel(text: tr("Timer"))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                        ForEach(presets, id: \.self) { m in
                            PresetButton(title: m == 60 ? tr("1 Std") : tr("\(m) Min")) { ts.start(seconds: Double(m) * 60) }
                        }
                    }
                    customRow
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(ts.timers) { t in TimerRow(timer: t) }
                        }
                    }
                    .frame(maxHeight: 108)
                    HStack(spacing: 6) {
                        ForEach([1, 5, 10, 25], id: \.self) { m in
                            PresetButton(title: tr("+ \(m) Min"), compact: true) { ts.start(seconds: Double(m) * 60) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            StopwatchCard().frame(width: 206)
        }
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            CircleButton(symbol: "minus", size: 26) { customMinutes = max(1, customMinutes - (customMinutes > 10 ? 5 : 1)) }
            Text(tr("\(customMinutes) Min"))
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 66)
            CircleButton(symbol: "plus", size: 26) { customMinutes = min(600, customMinutes + (customMinutes >= 10 ? 5 : 1)) }
            Spacer(minLength: 0)
            PillButton(title: tr("Starten"), symbol: "play.fill", tint: .orange, fg: .black) {
                ts.start(seconds: Double(customMinutes) * 60)
            }
        }
    }
}

struct PresetButton: View {
    let title: String
    var compact = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 6 : 8)
                .padding(.horizontal, compact ? 8 : 0)
                .background(Capsule().fill(Color.orange.opacity(hover ? 0.28 : 0.17)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct TimerRow: View {
    let timer: IslandTimer
    @ObservedObject var ts = TimerService.shared

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                HStack(spacing: 12) {
                    ZStack {
                        ProgressRing(progress: timer.progress(at: ctx.date), color: .orange, lineWidth: 4)
                        Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(formatRemaining(timer.remaining(at: ctx.date)))
                            .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(timer.isPaused ? Color.orange.opacity(0.6) : .orange)
                        Text(timer.label).font(.system(size: 11)).foregroundStyle(Color.dim)
                    }
                }
            }
            Spacer(minLength: 0)
            CircleButton(symbol: "plus", tint: Color.white.opacity(0.12), size: 32) { ts.addMinute(timer.id) }
                .help(tr("+1 Minute"))
            CircleButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", tint: Color.orange.opacity(0.25), fg: .orange, size: 32) {
                ts.togglePause(timer.id)
            }
            CircleButton(symbol: "xmark", tint: Color.white.opacity(0.12), size: 32) { ts.cancel(timer.id) }
        }
    }
}

struct StopwatchCard: View {
    @ObservedObject var ts = TimerService.shared

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: tr("Stoppuhr"))
                TimelineView(.animation(minimumInterval: 0.05, paused: !ts.swRunning)) { ctx in
                    Text(formatStopwatch(ts.swElapsed(at: ctx.date)))
                        .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                HStack {
                    Button { ts.swLapOrReset() } label: {
                        Text(ts.swRunning ? tr("Runde") : tr("Zurücksetzen"))
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 82, height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!ts.swRunning && ts.swAccum == 0)
                    Spacer(minLength: 0)
                    Button { ts.swToggle() } label: {
                        Text(ts.swRunning ? tr("Stopp") : tr("Start"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(ts.swRunning ? Color.red : Color.green)
                            .frame(width: 82, height: 30)
                            .background(Capsule().fill((ts.swRunning ? Color.red : Color.green).opacity(0.22)))
                    }
                    .buttonStyle(PressableStyle())
                }
                if let last = ts.laps.first {
                    HStack {
                        Text(tr("Runde \(ts.laps.count)"))
                        Spacer()
                        Text(formatStopwatch(last)).monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dim)
                }
            }
        }
    }
}
