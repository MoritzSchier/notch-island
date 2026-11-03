import SwiftUI
import AppKit

// MARK: - Form der Insel

/// Die Form der echten MacBook-Notch: oben nach außen geschwungene "Ohren", unten runde Ecken.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = topRadius
        let b = max(0, min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Übergänge

struct IslandMorph: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale, anchor: .top).opacity(opacity)
    }
}

extension AnyTransition {
    /// Wie auf dem iPhone: Inhalte "verschmelzen" mit Unschärfe und leichter Skalierung.
    static var island: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: IslandMorph(blur: 10, scale: 0.86, opacity: 0),
                                 identity: IslandMorph(blur: 0, scale: 1, opacity: 1))
                .animation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.06)),
            removal: .modifier(active: IslandMorph(blur: 8, scale: 0.9, opacity: 0),
                               identity: IslandMorph(blur: 0, scale: 1, opacity: 1))
                .animation(.easeOut(duration: 0.14))
        )
    }
}

// MARK: - Bausteine

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cardFill))
    }
}

struct CircleButton: View {
    let symbol: String
    var tint: Color = Color.white.opacity(0.14)
    var fg: Color = .white
    var size: CGFloat = 34
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: size, height: size)
                .background(Circle().fill(tint).brightness(hover ? 0.08 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    var active = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.white.opacity(hover ? 0.9 : 0.55))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(Color.white.opacity(active ? 0.16 : (hover ? 0.08 : 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = Color.white.opacity(0.12)
    var fg: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint).brightness(hover ? 0.08 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.3), value: progress)
    }
}

struct ProgressBar: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                Capsule().fill(color).frame(width: max(height, g.size.width * max(0, min(1, progress))))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: progress)
    }
}

struct IndeterminateBar: View {
    var color: Color
    var height: CGFloat = 5
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.2))
                    Capsule().fill(
                        LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: g.size.width * 0.4)
                    .offset(x: g.size.width * 1.4 * t - g.size.width * 0.4)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

/// Animierte Pegel-Balken rechts in der Insel, wie beim iPhone während Musik läuft.
struct AudioBars: View {
    var color: Color
    var playing: Bool
    var height: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.13, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (2.1 + Double(i) * 0.83) + Double(i) * 1.7
                    let h = playing ? 0.28 + 0.72 * abs(sin(phase) * cos(phase * 0.37)) : 0.22
                    Capsule().fill(color).frame(width: 3, height: max(3, height * h))
                }
            }
            .animation(.easeInOut(duration: 0.13), value: t)
        }
        .frame(height: height)
    }
}

struct BatteryIcon: View {
    var level: Double
    var charging: Bool
    var width: CGFloat = 24

    private var color: Color { charging ? .green : (level <= 0.2 ? .red : .white) }

    var body: some View {
        let h = width * 0.48
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.32, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
                RoundedRectangle(cornerRadius: h * 0.2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, (width - 4) * max(0, min(1, level))))
                    .padding(2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.72, weight: .heavy))
                        .foregroundStyle(level > 0.5 ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: h)
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.42)).frame(width: 1.5, height: h * 0.4)
        }
    }
}

/// Dicker Regler im iOS-Kontrollzentrum-Stil.
struct IslandSlider: View {
    @Binding var value: Double
    var tint: Color = .white
    var onEnded: (() -> Void)? = nil
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(0, g.size.width * max(0, min(1, value))))
            }
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        value = max(0, min(1, v.location.x / max(1, g.size.width)))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnded?()
                    }
            )
        }
        .frame(height: dragging || hover ? 8 : 5)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: dragging || hover)
        .onHover { hover = $0 }
    }
}

struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 20
    var body: some View {
        if let b = bundleID, let i = AppInfo.icon(b) {
            Image(nsImage: i).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill").font(.system(size: size * 0.8)).foregroundStyle(Color.dim).frame(width: size, height: size)
        }
    }
}

struct ClaudeGlyph: View {
    var size: CGFloat = 16
    var spinning = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { ctx in
            let angle = spinning ? ctx.date.timeIntervalSinceReferenceDate * 120 : 0
            Image(systemName: "sparkle")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.claude)
                .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: size + 2, height: size + 2)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Color.white.opacity(0.42))
    }
}
