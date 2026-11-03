import AppKit
import SwiftUI

enum MediaSource: String { case spotify, music, youtube, other }

struct NowPlaying: Equatable {
    var source: MediaSource
    var appBundleID: String
    var title: String
    var artist: String
    var album: String = ""
    var isPlaying: Bool
    var position: Double = 0
    var duration: Double = 0
    var fetchedAt = Date()
    var artworkKey: String = ""
    var artworkURL: URL? = nil
    var chromeWindow: Int = 0
    var chromeTab: Int = 0

    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let p = position + date.timeIntervalSince(fetchedAt)
        return duration > 0 ? min(duration, p) : p
    }

    var sourceName: String {
        switch source {
        case .spotify: return "Spotify"
        case .music: return "Musik"
        case .youtube: return "YouTube"
        case .other: return AppInfo.name(appBundleID)
        }
    }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.source == b.source && a.appBundleID == b.appBundleID && a.title == b.title && a.artist == b.artist
            && a.isPlaying == b.isPlaying && abs(a.position - b.position) < 2.5 && abs(a.duration - b.duration) < 1
            && a.artworkKey == b.artworkKey && a.chromeTab == b.chromeTab && a.chromeWindow == b.chromeWindow
    }
}

enum MediaKey: Int32 { case play = 16, next = 17, previous = 18 }

enum MediaKeys {
    /// Sendet eine echte Medientaste (▶︎❙❙ / ⏭ / ⏮) – funktioniert mit jeder App, die Medientasten unterstützt.
    static func post(_ key: MediaKey) {
        func send(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let state: Int32 = down ? 0xa : 0xb
            let data1 = Int((key.rawValue << 16) | (state << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        send(true)
        send(false)
    }
}

/// Liest "Jetzt läuft" aus Spotify, Apple Music und YouTube (Chrome) per AppleScript
/// und erkennt sonstige Audio-Wiedergabe über CoreAudio.
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var now: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = .white
    @Published private(set) var chromeJSBlocked = false

    private let queue = DispatchQueue(label: "notch.media", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:]
    private var timer: Timer?
    private var busy = false
    private var tickCount = 0
    private var lastChrome: NowPlaying?
    private var currentArtKey = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func poll() {
        guard !busy, Prefs.on(Prefs.showMedia) else { return }
        busy = true
        tickCount += 1
        let spotify = AppInfo.isRunning(Const.spotify)
        let music = AppInfo.isRunning(Const.music)
        let chrome = AppInfo.isRunning(Const.chrome)
        let audio = AudioProcessMonitor.shared.outputApps
        let chromeAudio = audio.contains(Const.chrome)
        let scanChrome = chrome && (chromeAudio || tickCount % 3 == 0)
        let prev = now

        queue.async { [weak self] in
            guard let self else { return }
            var cands: [NowPlaying] = []
            if spotify, let s = self.querySpotify() { cands.append(s) }
            if music, let m = self.queryMusic() { cands.append(m) }
            if chrome {
                if scanChrome { self.lastChrome = self.queryChrome(audioActive: chromeAudio) }
                if var y = self.lastChrome {
                    if !scanChrome && y.isPlaying { y.position = y.position(at: Date()); y.fetchedAt = Date() }
                    cands.append(y)
                }
            } else {
                self.lastChrome = nil
            }

            var chosen = cands.first(where: { $0.isPlaying })
            if chosen == nil, let prev, let same = cands.first(where: { $0.source == prev.source }) { chosen = same }
            if chosen == nil {
                let known: Set<String> = [Const.spotify, Const.music, Const.chrome, Const.bundleID]
                let allowedApple: Set<String> = ["com.apple.Safari", "com.apple.QuickTimePlayerX", "com.apple.TV", "com.apple.podcasts", "com.apple.iBooksX"]
                if let other = audio.sorted().first(where: { b in
                    !known.contains(b) && !CallMonitor.isCallApp(b) && (!b.hasPrefix("com.apple.") || allowedApple.contains(b))
                        && NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil
                }) {
                    chosen = NowPlaying(source: .other, appBundleID: other, title: AppInfo.name(other),
                                        artist: "Audio-Wiedergabe", isPlaying: true, artworkKey: "app:" + other)
                }
            }
            if chosen == nil { chosen = cands.first }

            DispatchQueue.main.async {
                self.busy = false
                self.apply(chosen)
            }
        }
    }

    private func apply(_ np: NowPlaying?) {
        if np != now { now = np }
        guard let np else {
            currentArtKey = ""
            if artwork != nil { artwork = nil; tint = .white }
            return
        }
        if np.artworkKey != currentArtKey {
            currentArtKey = np.artworkKey
            loadArtwork(np)
        }
    }

    // MARK: Artwork

    private func loadArtwork(_ np: NowPlaying) {
        let key = np.artworkKey
        switch np.source {
        case .music:
            queue.async { [weak self] in
                guard let self else { return }
                let d = self.run(nil, "tell application id \"com.apple.Music\" to return raw data of artwork 1 of current track")
                let img = d.flatMap { NSImage(data: $0.data) }
                DispatchQueue.main.async { self.setArtwork(img ?? AppInfo.icon(np.appBundleID), key: key) }
            }
        case .spotify, .youtube:
            guard let url = np.artworkURL else { setArtwork(AppInfo.icon(np.appBundleID), key: key); return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { self?.setArtwork(img ?? AppInfo.icon(np.appBundleID), key: key) }
            }.resume()
        case .other:
            setArtwork(AppInfo.icon(np.appBundleID), key: key)
        }
    }

    private func setArtwork(_ img: NSImage?, key: String) {
        guard key == currentArtKey else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            artwork = img
            tint = img.flatMap { Self.accentColor(of: $0) } ?? .white
        }
    }

    static func accentColor(of img: NSImage) -> Color? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Auf schwarzem Grund gut sichtbar machen
        return Color(hue: Double(h), saturation: Double(min(0.85, s * 1.2)), brightness: Double(max(0.78, b)))
    }

    // MARK: AppleScript

    private func run(_ cacheKey: String?, _ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let k = cacheKey, let s = scripts[k] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            if let k = cacheKey { scripts[k] = s }
            script = s
        }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        return err == nil ? r : nil
    }

    private func str(_ d: NSAppleEventDescriptor, _ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
    private func num(_ d: NSAppleEventDescriptor, _ i: Int) -> Double {
        guard let x = d.atIndex(i) else { return 0 }
        if let s = x.stringValue, let v = Double(s.replacingOccurrences(of: ",", with: ".")) { return v }
        return x.doubleValue
    }

    private func querySpotify() -> NowPlaying? {
        let src = """
        tell application id "com.spotify.client"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (player position), (artwork url of t), (id of t)}
        end tell
        """
        guard let d = run("spotify", src), d.numberOfItems >= 8 else { return nil }
        let state = str(d, 1)
        return NowPlaying(source: .spotify, appBundleID: Const.spotify, title: str(d, 2), artist: str(d, 3), album: str(d, 4),
                          isPlaying: state == "playing" || state == "kPSP", position: num(d, 6), duration: num(d, 5) / 1000,
                          artworkKey: "sp:" + str(d, 8), artworkURL: URL(string: str(d, 7)))
    }

    private func queryMusic() -> NowPlaying? {
        let src = """
        tell application id "com.apple.Music"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {(player state as string), (name of t), (artist of t), (album of t), (duration of t), (player position)}
        end tell
        """
        guard let d = run("music", src), d.numberOfItems >= 6 else { return nil }
        let state = str(d, 1)
        return NowPlaying(source: .music, appBundleID: Const.music, title: str(d, 2), artist: str(d, 3), album: str(d, 4),
                          isPlaying: state == "playing" || state == "kPSP", position: num(d, 6), duration: num(d, 5),
                          artworkKey: "mu:" + str(d, 2) + "|" + str(d, 4))
    }

    private static let chromeScan = """
    tell application id "com.google.Chrome"
        set out to {}
        set wi to 0
        repeat with w in windows
            set wi to wi + 1
            set ti to 0
            repeat with t in tabs of w
                set ti to ti + 1
                set u to URL of t
                if u contains "youtube.com/watch" or u contains "youtube.com/shorts" or u contains "music.youtube.com" then
                    set end of out to {u, title of t, wi, ti}
                end if
            end repeat
        end repeat
        return out
    end tell
    """

    private static let ytInfoJS = "(function(){var v=document.querySelector('video');if(!v)return '';var c=document.querySelector('#owner #channel-name a')||document.querySelector('ytd-video-owner-renderer #channel-name a')||document.querySelector('ytmusic-player-bar .byline a')||document.querySelector('.byline a');var t=document.querySelector('ytmusic-player-bar .title');return [v.paused?'0':'1',v.currentTime,v.duration,c?c.textContent.trim():'',t?t.textContent.trim():''].join('|');})()"

    private func chromeJS(window: Int, tab: Int, _ js: String) -> String? {
        let src = "tell application id \"com.google.Chrome\" to execute tab \(tab) of window \(window) javascript \"\(js)\""
        guard let d = run(nil, src) else { return nil }
        return d.stringValue ?? ""
    }

    private func queryChrome(audioActive: Bool) -> NowPlaying? {
        guard let list = run("chromeScan", Self.chromeScan), list.numberOfItems > 0 else { return nil }
        struct Tab { let url: String; let title: String; let w: Int; let t: Int }
        var tabs: [Tab] = []
        for i in 1...list.numberOfItems {
            guard let it = list.atIndex(i), it.numberOfItems >= 4 else { continue }
            tabs.append(Tab(url: it.atIndex(1)?.stringValue ?? "", title: it.atIndex(2)?.stringValue ?? "",
                            w: Int(it.atIndex(3)?.int32Value ?? 1), t: Int(it.atIndex(4)?.int32Value ?? 1)))
        }
        guard !tabs.isEmpty else { return nil }

        var best: (Tab, [String])?
        var jsWorked = false
        for tab in tabs.prefix(5) {
            guard let r = chromeJS(window: tab.w, tab: tab.t, Self.ytInfoJS) else { continue }
            jsWorked = true
            let parts = r.components(separatedBy: "|")
            guard parts.count >= 5 else { continue }
            if best == nil || parts[0] == "1" { best = (tab, parts) }
            if parts[0] == "1" { break }
        }
        let blocked = !jsWorked
        if blocked != chromeJSBlocked { DispatchQueue.main.async { self.chromeJSBlocked = blocked } }

        let tab = best?.0 ?? tabs[0]
        let parts = best?.1
        var title = Self.cleanTitle(tab.title)
        if let p = parts, !p[4].isEmpty { title = p[4] }
        let videoID = Self.videoID(tab.url)
        let playing = parts.map { $0[0] == "1" } ?? audioActive
        return NowPlaying(source: .youtube, appBundleID: Const.chrome, title: title,
                          artist: parts?[3] ?? "YouTube", isPlaying: playing,
                          position: parts.flatMap { Double($0[1]) } ?? 0,
                          duration: parts.flatMap { Double($0[2]) }.flatMap { $0.isFinite ? $0 : nil } ?? 0,
                          artworkKey: "yt:" + (videoID ?? tab.url),
                          artworkURL: videoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") },
                          chromeWindow: tab.w, chromeTab: tab.t)
    }

    static func cleanTitle(_ t: String) -> String {
        var s = t
        if let r = s.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        for suffix in [" - YouTube Music", " - YouTube"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s
    }

    static func videoID(_ url: String) -> String? {
        guard let c = URLComponents(string: url) else { return nil }
        if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        if c.path.contains("/shorts/") { return c.path.components(separatedBy: "/").last }
        return nil
    }

    // MARK: Steuerung

    private func control(spotify: String, music: String, youtubeJS: String, key: MediaKey) {
        guard let np = now else { MediaKeys.post(key); return }
        queue.async { [weak self] in
            guard let self else { return }
            switch np.source {
            case .spotify: _ = self.run(nil, "tell application id \"com.spotify.client\" to \(spotify)")
            case .music: _ = self.run(nil, "tell application id \"com.apple.Music\" to \(music)")
            case .youtube:
                if self.chromeJS(window: np.chromeWindow, tab: np.chromeTab, youtubeJS) == nil {
                    DispatchQueue.main.async { MediaKeys.post(key) }
                }
            case .other: DispatchQueue.main.async { MediaKeys.post(key) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.poll() }
        }
    }

    func togglePlay() {
        if var np = now {
            np.position = np.position(at: Date())
            np.fetchedAt = Date()
            np.isPlaying.toggle()
            now = np
        }
        control(spotify: "playpause", music: "playpause",
                youtubeJS: "(function(){var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}return ''})()",
                key: .play)
    }

    func next() {
        control(spotify: "next track", music: "next track",
                youtubeJS: "(function(){var b=document.querySelector('.ytp-next-button')||document.querySelector('ytmusic-player-bar .next-button');if(b)b.click();return ''})()",
                key: .next)
    }

    func previous() {
        control(spotify: "previous track", music: "previous track",
                youtubeJS: "(function(){var v=document.querySelector('video');if(v&&v.currentTime>3){v.currentTime=0}else{var b=document.querySelector('ytmusic-player-bar .previous-button');if(b){b.click()}else{history.back()}}return ''})()",
                key: .previous)
    }

    func seek(to seconds: Double) {
        guard let np = now else { return }
        let s = String(format: "%.2f", seconds)
        var copy = np
        copy.position = seconds
        copy.fetchedAt = Date()
        now = copy
        queue.async { [weak self] in
            guard let self else { return }
            switch np.source {
            case .spotify: _ = self.run(nil, "tell application id \"com.spotify.client\" to set player position to \(s)")
            case .music: _ = self.run(nil, "tell application id \"com.apple.Music\" to set player position to \(s)")
            case .youtube: _ = self.chromeJS(window: np.chromeWindow, tab: np.chromeTab, "(function(){var v=document.querySelector('video');if(v)v.currentTime=\(s);return ''})()")
            case .other: break
            }
        }
    }
}
