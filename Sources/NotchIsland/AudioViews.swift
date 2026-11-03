import SwiftUI
import AppKit
import CoreAudio

// MARK: - Audio-Geräte (Ein- und Ausgabe)

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    func symbol(input: Bool) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return input ? "mic.fill" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return BluetoothMonitor.symbol(for: name)
        case kAudioDeviceTransportTypeUSB: return input ? "mic.fill" : "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        case kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up.fill"
        default: return input ? "mic.fill" : "speaker.wave.2.fill"
        }
    }
}

final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID = 0
    @Published private(set) var defaultInput: AudioDeviceID = 0
    @Published private(set) var inputVolume: Double?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var a = CA.addr(sel)
            AudioObjectAddPropertyListenerBlock(CA.system, &a, DispatchQueue.main) { [weak self] _, _ in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        var a = CA.addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CA.system, &a, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(CA.system, &a, 0, nil, &size, &ids) == noErr else { return }
        var outs: [AudioDevice] = [], ins: [AudioDevice] = []
        for id in ids {
            let name = CA.string(id, CA.addr(kAudioObjectPropertyName)) ?? "Gerät"
            let transport = CA.getU32(id, CA.addr(kAudioDevicePropertyTransportType)) ?? 0
            let d = AudioDevice(id: id, name: name, transport: transport)
            if Self.hasStreams(id, input: false) { outs.append(d) }
            if Self.hasStreams(id, input: true) { ins.append(d) }
        }
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
        defaultOutput = CA.defaultDevice(input: false)
        defaultInput = CA.defaultDevice(input: true)
        readInputVolume()
    }

    private static func hasStreams(_ id: AudioDeviceID, input: Bool) -> Bool {
        var a = CA.addr(kAudioDevicePropertyStreams, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    func setDefault(_ id: AudioDeviceID, input: Bool) {
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = CA.addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(CA.system, &a, 0, nil, size, &dev)
        if !input {
            // Systemtöne mitnehmen
            var s = CA.addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(CA.system, &s, 0, nil, size, &dev)
        }
        haptic()
        refresh()
    }

    // Eingangslautstärke (Mikrofonpegel)
    private func inputVolAddr(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    private func readInputVolume() {
        let dev = defaultInput
        if let v = CA.getFloat(dev, inputVolAddr(kAudioObjectPropertyElementMain)) { inputVolume = Double(v); return }
        if let v = CA.getFloat(dev, inputVolAddr(1)) { inputVolume = Double(v); return }
        inputVolume = nil
    }

    func setInputVolume(_ v: Double) {
        let dev = defaultInput
        if CA.settable(dev, inputVolAddr(kAudioObjectPropertyElementMain)) {
            CA.setFloat(dev, inputVolAddr(kAudioObjectPropertyElementMain), Float(v))
        } else {
            for ch: UInt32 in [1, 2] where CA.settable(dev, inputVolAddr(ch)) { CA.setFloat(dev, inputVolAddr(ch), Float(v)) }
        }
        inputVolume = v
    }
}

// MARK: - Tab

struct AudioTabView: View {
    @ObservedObject var audio = AudioDevices.shared
    @ObservedObject var calls = CallMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            column(title: "Ausgabe", devices: audio.outputs, selected: audio.defaultOutput, input: false) {
                VolumeRow()
            }
            column(title: "Eingabe", devices: audio.inputs, selected: audio.defaultInput, input: true) {
                HStack(spacing: 9) {
                    Button { calls.toggleMute() } label: {
                        Image(systemName: calls.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(calls.micMuted ? Color.orange : Color.white.opacity(0.65))
                            .frame(width: 16)
                    }
                    .buttonStyle(PressableStyle())
                    .help(calls.micMuted ? "Mikrofon einschalten" : "Mikrofon stummschalten")
                    if audio.inputVolume != nil {
                        IslandSlider(value: Binding(get: { audio.inputVolume ?? 0 }, set: { audio.setInputVolume($0) }))
                        Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.65))
                    } else {
                        Text("Pegel nicht regelbar").font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.4))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .onAppear { audio.refresh() }
    }

    private func column<Footer: View>(title: String, devices: [AudioDevice], selected: AudioDeviceID, input: Bool,
                                      @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: title)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(devices) { d in
                        AudioDeviceRow(device: d, input: input, selected: d.id == selected)
                    }
                }
            }
            Spacer(minLength: 0)
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct AudioDeviceRow: View {
    let device: AudioDevice
    let input: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        Button { AudioDevices.shared.setDefault(device.id, input: input) } label: {
            HStack(spacing: 9) {
                Image(systemName: device.symbol(input: input))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(selected ? Color.white : Color.white.opacity(0.1)))
                Text(device.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : (selected ? 0.07 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}
