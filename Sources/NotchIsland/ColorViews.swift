import SwiftUI
import AppKit

// MARK: - Farbmodell

struct RGBColor: Equatable {
    var r: Double, g: Double, b: Double   // 0…1, sRGB

    init(r: Double, g: Double, b: Double) {
        self.r = max(0, min(1, r)); self.g = max(0, min(1, g)); self.b = max(0, min(1, b))
    }

    init?(ns: NSColor) {
        guard let c = ns.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    init?(hex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0X") { s.removeFirst(2) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    var ints: (Int, Int, Int) { (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    var color: Color { Color(red: r, green: g, blue: b) }
    var hex: String { let (r, g, b) = ints; return String(format: "#%02X%02X%02X", r, g, b) }
    var rgbString: String { let (r, g, b) = ints; return "rgb(\(r), \(g), \(b))" }

    var binary: String {
        let (r, g, b) = ints
        func bin(_ v: Int) -> String {
            let s = String(v, radix: 2)
            return String(repeating: "0", count: max(0, 8 - s.count)) + s
        }
        return "\(bin(r)) \(bin(g)) \(bin(b))"
    }

    var hsl: (Int, Int, Int) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return (Int((h * 360).rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    var hslString: String { let (h, s, l) = hsl; return "hsl(\(h), \(s)%, \(l)%)" }
    var swiftUI: String { String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b) }

    /// Helle Farbe? Dann dunkle Schrift darauf.
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.6 }
}

final class ColorStore: ObservableObject {
    static let shared = ColorStore()
    private let key = "colorHistory"

    @Published private(set) var current: RGBColor?
    @Published private(set) var history: [String] = []
    @Published private(set) var picking = false
    private var sampler: NSColorSampler?

    init() {
        history = UserDefaults.standard.stringArray(forKey: key) ?? []
        current = history.first.flatMap { RGBColor(hex: $0) }
    }

    /// Pipette: beliebige Farbe auf dem Bildschirm aufnehmen.
    func pick() {
        guard !picking else { return }
        picking = true
        let model = IslandModel.shared
        // Insel einklappen und ausblenden, damit man auch Farben dahinter aufnehmen kann
        model.collapse()
        let window = model.hostView?.window
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window?.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let s = NSColorSampler()
            self.sampler = s
            s.show { [weak self] ns in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.picking = false
                    self.sampler = nil
                    if let ns, let c = RGBColor(ns: ns) { self.set(c) }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        window?.animator().alphaValue = 1
                    }
                    model.expand(tab: .colors)
                    model.holdOpen(seconds: 10)
                }
            }
        }
    }

    func set(_ c: RGBColor) {
        current = c
        history.removeAll { $0 == c.hex }
        history.insert(c.hex, at: 0)
        if history.count > 24 { history.removeLast(history.count - 24) }
        save()
        haptic()
    }

    func select(_ hex: String) {
        if let c = RGBColor(hex: hex) { current = c }
    }

    func remove(_ hex: String) {
        history.removeAll { $0 == hex }
        save()
    }

    func clear() {
        history = []
        save()
    }

    private func save() { UserDefaults.standard.set(history, forKey: key) }

    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        haptic()
    }
}

// MARK: - Tab

struct ColorTabView: View {
    @ObservedObject var store = ColorStore.shared
    @State private var hexInput = ""
    @FocusState private var hexFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Farbe + Pipette
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(store.current?.color ?? Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    if store.current == nil {
                        Image(systemName: "eyedropper.halffull").font(.system(size: 24)).foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .frame(width: 96, height: 96)
                .animation(.easeInOut(duration: 0.25), value: store.current)
                .onTapGesture { if let c = store.current { ColorStore.copy(c.hex) } }
                .help("Klicken kopiert den HEX-Code")
                Button { store.pick() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eyedropper").font(.system(size: 11, weight: .semibold))
                        Text(store.picking ? "Klicke …" : "Pipette").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(width: 96, height: 28)
                    .background(Capsule().fill(Color.white))
                }
                .buttonStyle(PressableStyle())
                TextField("#HEX", text: $hexInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($hexFocused)
                    .frame(width: 96, height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit {
                        if let c = RGBColor(hex: hexInput) { store.set(c); hexInput = "" }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        IslandModel.shared.hostView?.window?.makeKey()
                        hexFocused = true
                    })
            }

            // Darstellungen
            VStack(alignment: .leading, spacing: 4) {
                if let c = store.current {
                    ColorFormatRow(label: "HEX", value: c.hex)
                    ColorFormatRow(label: "RGB", value: c.rgbString)
                    ColorFormatRow(label: "Binär", value: c.binary)
                    ColorFormatRow(label: "HSL", value: c.hslString)
                    ColorFormatRow(label: "SwiftUI", value: c.swiftUI)
                } else {
                    Text("Mit der Pipette eine Farbe irgendwo auf dem Bildschirm aufnehmen – oder einen HEX-Code eingeben.")
                        .font(.system(size: 12)).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // Verlauf
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SectionLabel(text: "Verlauf")
                    Spacer()
                    if !store.history.isEmpty {
                        Button { withAnimation { store.clear() } } label: {
                            Text("Leeren").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.history.isEmpty {
                    Text("Noch keine Farben").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 7), count: 6), spacing: 7) {
                    ForEach(store.history, id: \.self) { hex in
                        HistorySwatch(hex: hex, selected: store.current?.hex == hex)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 200)
        }
    }
}

struct ColorFormatRow: View {
    let label: String
    let value: String
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 46, alignment: .leading)
            Text(copied ? "Kopiert" : value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(copied ? Color.green : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.white.opacity(hover ? 0.7 : 0))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            ColorStore.copy(value)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { withAnimation { copied = false } }
        }
        .help("Klicken zum Kopieren")
    }
}

struct HistorySwatch: View {
    let hex: String
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let c = RGBColor(hex: hex)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(c?.color ?? .gray)
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1))
            .scaleEffect(hover ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .onHover { hover = $0 }
            .onTapGesture { ColorStore.shared.select(hex) }
            .contextMenu {
                Button("HEX kopieren") { ColorStore.copy(hex) }
                if let c { Button("RGB kopieren") { ColorStore.copy(c.rgbString) } }
                Divider()
                Button("Entfernen") { ColorStore.shared.remove(hex) }
            }
            .help(hex)
    }
}
