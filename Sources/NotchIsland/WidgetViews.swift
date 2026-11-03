import SwiftUI
import AppKit
import AVFoundation

struct WidgetsView: View {
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ForEach(WidgetTab.allCases) { w in
                    let sel = model.widgetTab == w
                    Button { withAnimation(.easeInOut(duration: 0.15)) { model.widgetTab = w } } label: {
                        Label(w.rawValue, systemImage: w.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(sel ? Color.black : Color.white.opacity(0.75))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(sel ? Color.white : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer(minLength: 0)
            }
            Group {
                switch model.widgetTab {
                case .system: SystemWidget()
                case .clipboard: ClipboardWidget()
                case .note: NoteWidget()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - System

struct SystemWidget: View {
    @ObservedObject var battery = BatteryMonitor.shared
    @ObservedObject var bt = BluetoothMonitor.shared
    @ObservedObject var vol = VolumeController.shared
    @ObservedObject var bright = BrightnessMonitor.shared
    @ObservedObject var calls = CallMonitor.shared
    @ObservedObject var cam = CameraMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BatteryDetailCard().frame(width: 250)
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Bluetooth")
                    if bt.devices.isEmpty {
                        Text("Keine Geräte verbunden").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                    }
                    ForEach(bt.devices.prefix(3)) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.symbol).font(.system(size: 11)).frame(width: 16)
                            Text(d.name).font(.system(size: 11.5)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let b = d.battery {
                                Text("\(b) %").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.dim)
                            }
                        }
                    }
                }
            }
            .frame(width: 170)
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).frame(width: 16)
                        IslandSlider(value: Binding(get: { vol.muted ? 0 : vol.volume }, set: { vol.setVolume($0) }))
                    }
                    if bright.available {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.max.fill").font(.system(size: 11)).frame(width: 16)
                            IslandSlider(value: Binding(get: { bright.brightness }, set: { bright.set($0) }))
                        }
                    }
                    HStack(spacing: 10) {
                        privacyDot(on: !calls.micApps.isEmpty || calls.active != nil, color: .orange, symbol: "mic.fill")
                        privacyDot(on: cam.inUse, color: .green, symbol: "video.fill")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func privacyDot(on: Bool, color: Color, symbol: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? color : Color.white.opacity(0.2)).frame(width: 6, height: 6)
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(on ? color : Color.white.opacity(0.4))
        }
    }
}

// MARK: - Akku im Detail (wie coconutBattery)

struct BatteryDetailCard: View {
    @ObservedObject var battery = BatteryMonitor.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    BatteryIcon(level: battery.level, charging: battery.onAC, width: 30)
                    Text("\(Int((battery.level * 100).rounded())) %").font(.system(size: 16, weight: .semibold).monospacedDigit())
                    Spacer(minLength: 0)
                    if let d = battery.details, abs(d.watts) >= 0.1 {
                        HStack(spacing: 3) {
                            Image(systemName: d.watts > 0 ? "bolt.fill" : "arrow.down")
                                .font(.system(size: 10, weight: .bold))
                            Text(String(format: "%.1f W", abs(d.watts)))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(d.watts > 0 ? Color.green : Color.orange)
                        .help(d.watts > 0 ? "Wird geladen mit" : "Verbrauch")
                    }
                }
                Text(statusLine).font(.system(size: 11)).foregroundStyle(Color.dim).lineLimit(1)
                if let d = battery.details {
                    HStack(spacing: 12) {
                        stat(health(d), "Zustand", color: d.health >= 0.8 ? .white : .orange)
                        stat("\(d.cycles)", "Zyklen")
                        if let t = d.temperature { stat(String(format: "%.0f °C", t), "Temp.") }
                        if let a = d.adapterWatts, battery.onAC { stat("\(a) W", "Netzteil") }
                    }
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    Label("Stromsparmodus", systemImage: "leaf.fill").font(.system(size: 10.5)).foregroundStyle(.yellow)
                }
            }
        }
    }

    private var statusLine: String {
        guard let d = battery.details else { return battery.statusText }
        if d.watts > 0.1 {
            if let m = d.minutesTo80 { return "Lädt · 80 % in ca. \(Self.hm(m))" }
            if d.aboveOrAt80 { return battery.minutesLeft.map { "Lädt · über 80 % · voll in ca. \(Self.hm($0))" } ?? "Lädt · über 80 %" }
            return "Lädt"
        }
        if battery.onAC { return battery.level >= 0.995 ? "Vollständig geladen" : "Am Netzteil, lädt nicht (Ladelimit?)" }
        return battery.minutesLeft.map { "Akku · noch ca. \(Self.hm($0))" } ?? "Akkubetrieb"
    }

    private func health(_ d: BatteryMonitor.BatteryDetails) -> String {
        "\(Int((d.health * 100).rounded())) %"
    }

    private static func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60) Std \(m % 60) Min" : "\(m) Min" }

    private func stat(_ value: String, _ label: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45))
        }
    }
}

// MARK: - Spiegel

struct MirrorTabView: View {
    @State private var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.06))
                if allowed {
                    CameraPreview().clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    PillButton(title: "Kamera erlauben", symbol: "camera.fill") {
                        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { allowed = ok } }
                    }
                }
            }
            .frame(width: 270, height: 152)
            VStack(alignment: .leading, spacing: 6) {
                Label("Spiegel", systemImage: "person.crop.square").font(.system(size: 15, weight: .semibold))
                Text("Kurzer Check vor dem Call. Die Kamera läuft nur, solange dieser Tab offen ist – das grüne Licht geht danach wieder aus.")
                    .font(.system(size: 12)).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MirrorWidget: View {
    @State private var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06))
                if allowed {
                    CameraPreview()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    PillButton(title: "Kamera erlauben", symbol: "camera.fill") {
                        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { allowed = ok } }
                    }
                }
            }
            .frame(width: 196, height: 128)
            VStack(alignment: .leading, spacing: 4) {
                Text("Spiegel").font(.system(size: 14, weight: .semibold))
                Text("Kurzer Check vor dem Call – die Kamera läuft nur, solange dieser Tab offen ist.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer

    override init(frame: NSRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = CALayer()
        layer?.addSublayer(previewLayer)
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        MirrorState.active = true
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func stop() {
        MirrorState.active = false
        let s = session
        DispatchQueue.global().async { s.stopRunning() }
    }
}

struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(frame: .zero) }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) { nsView.stop() }
}

// MARK: - Zwischenablage

struct ClipboardWidget: View {
    @ObservedObject var clip = ClipboardHistory.shared

    var body: some View {
        if clip.items.isEmpty {
            Text(Prefs.on(Prefs.clipboardHistory) ? "Kopierte Texte erscheinen hier (nur im Arbeitsspeicher, Passwörter werden ignoriert)." : "Zwischenablage-Verlauf ist in den Einstellungen ausgeschaltet.")
                .font(.system(size: 12)).foregroundStyle(Color.dim)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(clip.items.count == 1 ? "1 Eintrag" : "\(clip.items.count) Einträge")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
                    Text("· Klicken zum Kopieren").font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.3))
                    Spacer()
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { clip.clear() } } label: {
                        Label("Alle löschen", systemImage: "trash").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(clip.items) { c in
                            ClipRow(clip: c).transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: clip.items)
                }
            }
        }
    }
}

struct ClipRow: View {
    let clip: ClipboardHistory.Clip
    @ObservedObject var model = IslandModel.shared
    @State private var hover = false
    @State private var copied = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                HStack(alignment: .top, spacing: 8) {
                    TextField("Text", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(save)
                    Button(action: save) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.green)
                    }
                    .buttonStyle(.plain).help("Speichern")
                    Button(action: endEditing) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.plain).help("Abbrechen")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.blue.opacity(0.7), lineWidth: 1))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copied ? Color.green : Color.white.opacity(0.4))
                        .frame(width: 12)
                    Text(copied ? "Kopiert" : clip.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .font(.system(size: 11.5)).lineLimit(1)
                        .foregroundStyle(copied ? Color.green : Color.white)
                    Spacer(minLength: 0)
                    if hover {
                        Button { startEditing() } label: {
                            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.7)).help("Bearbeiten")
                        Button { withAnimation { ClipboardHistory.shared.remove(clip.id) } } label: {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.red).help("Löschen")
                    } else {
                        Text(clip.date, style: .time).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Rectangle())
                .onTapGesture {
                    ClipboardHistory.shared.copy(clip)
                    haptic()
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { withAnimation { copied = false } }
                }
                .onHover { hover = $0 }
                .help(clip.text)
            }
        }
    }

    private func startEditing() {
        draft = clip.text
        editing = true
        model.hostView?.window?.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
    }

    private func save() {
        ClipboardHistory.shared.update(clip.id, text: draft)
        endEditing()
    }

    private func endEditing() {
        editing = false

    }
}

// MARK: - Notiz

struct NoteWidget: View {
    @AppStorage(Prefs.quickNote) private var note = ""
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        TextEditor(text: $note)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardFill))
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text("Schnelle Notiz …").font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.35))
                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .onAppear {
                model.hostView?.window?.makeKey()
            }
    }
}
