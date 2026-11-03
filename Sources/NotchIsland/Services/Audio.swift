import AppKit
import CoreAudio
import AudioToolbox
import CoreMediaIO
import Combine

// MARK: - CoreAudio Hilfen

enum CA {
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    static func has(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(id, &a)
    }

    static func settable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &s) == noErr && s.boolValue
    }

    static func getFloat(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Float? {
        var a = a
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setFloat(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var a = a
        var v = Float32(value)
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func getU32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
        var a = a
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setU32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var a = a
        var v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    static func string(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
        var a = a
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr)
        }
        guard st == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }
}

// MARK: - Welche App nutzt Mikrofon / Lautsprecher? (macOS 14+)

final class AudioProcessMonitor: ObservableObject {
    static let shared = AudioProcessMonitor()

    @Published private(set) var inputApps: Set<String> = []
    @Published private(set) var outputApps: Set<String> = []
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func processObjects() -> [AudioObjectID] {
        var a = CA.addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CA.system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CA.system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func poll() {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        var ins = Set<String>(), outs = Set<String>()
        for obj in processObjects() {
            let inp = (CA.getU32(obj, CA.addr(kAudioProcessPropertyIsRunningInput)) ?? 0) != 0
            let out = (CA.getU32(obj, CA.addr(kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0
            guard inp || out else { continue }
            guard let bid = CA.string(obj, CA.addr(kAudioProcessPropertyBundleID)), !bid.isEmpty else { continue }
            let owner = Self.owner(of: bid, running: running)
            if owner == Const.bundleID || owner.hasPrefix("com.apple.audio") || owner == "com.apple.coreaudiod" { continue }
            if inp { ins.insert(owner) }
            if out { outs.insert(owner) }
        }
        if ins != inputApps { inputApps = ins }
        if outs != outputApps { outputApps = outs }
    }

    /// Hilfsprozesse (z. B. "com.google.Chrome.helper") der eigentlichen App zuordnen.
    static func owner(of bid: String, running: [String]) -> String {
        if bid.hasPrefix("com.apple.WebKit") {
            return running.contains("com.apple.Safari") ? "com.apple.Safari" : bid
        }
        var best: String?
        for r in running where bid == r || bid.hasPrefix(r + ".") {
            if best == nil || r.count > best!.count { best = r }
        }
        return best ?? bid
    }
}

// MARK: - Lautstärke

final class VolumeController: ObservableObject {
    static let shared = VolumeController()

    @Published private(set) var volume: Double = 0.5
    @Published private(set) var muted = false

    private var device: AudioDeviceID = 0
    private var ready = false
    private var selfChangeUntil = Date.distantPast
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.read(fromSystem: true) }
    }

    private var volumeAddr: AudioObjectPropertyAddress {
        CA.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    }
    private var muteAddr: AudioObjectPropertyAddress { CA.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) }

    func start() {
        var a = CA.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &a, DispatchQueue.main) { [weak self] _, _ in self?.attach() }
        attach()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.ready = true }
    }

    private func attach() {
        if device != 0 {
            var v = volumeAddr, m = muteAddr
            AudioObjectRemovePropertyListenerBlock(device, &v, DispatchQueue.main, listener)
            AudioObjectRemovePropertyListenerBlock(device, &m, DispatchQueue.main, listener)
        }
        device = CA.defaultDevice(input: false)
        var v = volumeAddr, m = muteAddr
        AudioObjectAddPropertyListenerBlock(device, &v, DispatchQueue.main, listener)
        AudioObjectAddPropertyListenerBlock(device, &m, DispatchQueue.main, listener)
        read(fromSystem: false)
    }

    private func read(fromSystem: Bool) {
        let v = Double(CA.getFloat(device, volumeAddr) ?? Float(volume))
        let m = (CA.getU32(device, muteAddr) ?? 0) != 0
        let changed = abs(v - volume) > 0.001 || m != muted
        if abs(v - volume) > 0.001 { volume = v }
        if m != muted { muted = m }
        if changed && fromSystem && ready && Date() > selfChangeUntil && Prefs.on(Prefs.showVolumeHUD) {
            IslandModel.shared.showHUD(.volume(v, muted: m))
        }
    }

    func setVolume(_ v: Double) {
        selfChangeUntil = Date().addingTimeInterval(0.8)
        CA.setFloat(device, volumeAddr, Float(v))
        if muted && v > 0.01 { CA.setU32(device, muteAddr, 0); muted = false }
        volume = v
    }

    func toggleMute() {
        selfChangeUntil = Date().addingTimeInterval(0.8)
        let new = !muted
        CA.setU32(device, muteAddr, new ? 1 : 0)
        muted = new
    }
}

// MARK: - Anrufe (WhatsApp, Discord, FaceTime, Zoom, Teams, …)

struct CallInfo: Equatable {
    let bundleID: String
    let name: String
    let start: Date
}

final class CallMonitor: ObservableObject {
    static let shared = CallMonitor()

    @Published private(set) var active: CallInfo?
    @Published private(set) var ringing: CallInfo?
    @Published private(set) var micApps: [String] = []
    @Published private(set) var micMuted = false

    private var endWork: DispatchWorkItem?
    private var dismissedRinging: String?
    private var savedInputVolume: Float?
    private var bag = Set<AnyCancellable>()

    static var callApps: [String: String] { [
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.hnc.Discord": tr("Discord"),
        "com.apple.FaceTime": "FaceTime",
        "com.apple.TelephonyUtilities": tr("Telefon"),
        "com.apple.telephonyutilities.callservicesd": tr("Telefon"),
        "us.zoom.xos": tr("Zoom"),
        "com.microsoft.teams2": tr("Teams"),
        "com.microsoft.teams": tr("Teams"),
        "com.tinyspeck.slackmacgap": tr("Slack"),
        "ru.keepcoder.Telegram": tr("Telegram"),
        "com.tdesktop.Telegram": tr("Telegram"),
        "com.skype.skype": tr("Skype"),
        "com.cisco.webexmeetingsapp": tr("Webex"),
        "com.google.Chrome": tr("Chrome"),
        "com.apple.Safari": tr("Safari"),
        "company.thebrowser.Browser": tr("Arc"),
        "org.mozilla.firefox": tr("Firefox"),
        "com.microsoft.edgemac": tr("Edge"),
        "com.brave.Browser": tr("Brave"),
        "com.apple.Messages": tr("Nachrichten"),
        "com.signal.Signal": tr("Signal"),
        "org.whispersystems.signal-desktop": tr("Signal"),
    ] }
    static let ringApps = ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.FaceTime",
                           "com.apple.TelephonyUtilities", "com.apple.telephonyutilities.callservicesd"]

    static func callName(_ b: String) -> String? {
        if let n = callApps[b] { return n }
        if b.lowercased().contains("callservices") { return "Telefon" }
        return callApps.first(where: { b.hasPrefix($0.key + ".") })?.value
    }

    static func isCallApp(_ b: String) -> Bool { callName(b) != nil }

    func start() {
        let a = AudioProcessMonitor.shared
        a.$inputApps.combineLatest(a.$outputApps)
            .receive(on: RunLoop.main)
            .sink { [weak self] i, o in self?.evaluate(i, o) }
            .store(in: &bag)
    }

    private func evaluate(_ ins: Set<String>, _ outs: Set<String>) {
        let callIn = ins.sorted().first { Self.callName($0) != nil }
        if let b = callIn {
            endWork?.cancel()
            endWork = nil
            if active?.bundleID != b {
                let isNew = active == nil
                active = CallInfo(bundleID: b, name: Self.callName(b) ?? AppInfo.name(b), start: active?.start ?? Date())
                ringing = nil
                if isNew { micMuted = inputMuted() }
            }
        } else if active != nil, endWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let a = self.active {
                    let dur = formatDuration(Date().timeIntervalSince(a.start))
                    IslandModel.shared.show(Toast(symbol: "phone.down.fill", tint: .red, title: tr("Anruf beendet"),
                                                  subtitle: "\(a.name) · \(dur)", duration: 2.5))
                }
                if self.micMuted { self.setInputMuted(false) }
                self.active = nil
                self.endWork = nil
            }
            endWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        }

        let mics = ins.filter { Self.callName($0) == nil }.sorted()
        if mics != micApps { micApps = mics }

        // Klingeln: Anruf-App spielt Ton, nutzt aber (noch) kein Mikrofon und ist nicht im Vordergrund.
        let front = AppInfo.frontmost
        let ring = outs.first { b in
            Self.ringApps.contains(where: { b == $0 || b.hasPrefix($0 + ".") }) && !ins.contains(b) && front != b
        }
        if active == nil, let r = ring {
            if dismissedRinging != r && ringing?.bundleID != r {
                ringing = CallInfo(bundleID: r, name: Self.callName(r) ?? AppInfo.name(r), start: Date())
            }
        } else {
            if ringing != nil { ringing = nil }
            if let d = dismissedRinging, !outs.contains(d) { dismissedRinging = nil }
        }
    }

    func answer() {
        if let r = ringing { AppInfo.activate(r.bundleID) }
        ringing = nil
    }

    func dismissRinging() {
        dismissedRinging = ringing?.bundleID
        ringing = nil
    }

    // Mikrofon stummschalten (systemweit am Eingabegerät)
    private func inputMuted() -> Bool {
        let dev = CA.defaultDevice(input: true)
        return (CA.getU32(dev, CA.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)) ?? 0) != 0
    }

    private func setInputMuted(_ m: Bool) {
        let dev = CA.defaultDevice(input: true)
        let muteA = CA.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        if CA.settable(dev, muteA) {
            CA.setU32(dev, muteA, m ? 1 : 0)
        } else {
            let volA = CA.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
            if m {
                savedInputVolume = CA.getFloat(dev, volA)
                CA.setFloat(dev, volA, 0)
            } else {
                CA.setFloat(dev, volA, savedInputVolume ?? 0.75)
            }
        }
        micMuted = m
    }

    func toggleMute() {
        setInputMuted(!micMuted)
        haptic()
    }
}

// MARK: - Kamera aktiv?

final class CameraMonitor: ObservableObject {
    static let shared = CameraMonitor()
    @Published private(set) var inUse = false
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let v = Self.cameraInUse()
            if v != self.inUse { self.inUse = v }
        }
    }

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        for d in devices {
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var v: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &v) == 0, v != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Helligkeit (eingebautes Display)

final class BrightnessMonitor: ObservableObject {
    static let shared = BrightnessMonitor()

    @Published private(set) var brightness: Double = 0.5
    @Published private(set) var available = false

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var display: CGDirectDisplayID = CGMainDisplayID()
    private var last: Float = -1
    private var selfChangeUntil = Date.distantPast
    private var timer: Timer?

    func start() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let s = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(s, to: GetFn.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: SetFn.self) }
        }
        display = Self.builtinDisplay()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private static func builtinDisplay() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    private func poll() {
        guard let getFn else { return }
        var v: Float = 0
        guard getFn(display, &v) == 0 else { return }
        if !available { available = true }
        if last < 0 { last = v; brightness = Double(v); return }
        let delta = abs(v - last)
        guard delta > 0.004 else { return }
        brightness = Double(v)
        last = v
        guard Date() > selfChangeUntil, Prefs.on(Prefs.showBrightnessHUD) else { return }
        let model = IslandModel.shared
        if case .hud(.brightness(_)) = model.presentation {
            model.showHUD(.brightness(Double(v)))
        } else if delta > 0.02 {
            model.showHUD(.brightness(Double(v)))
        }
    }

    func set(_ v: Double) {
        selfChangeUntil = Date().addingTimeInterval(0.8)
        _ = setFn?(display, Float(v))
        brightness = v
        last = Float(v)
    }
}
