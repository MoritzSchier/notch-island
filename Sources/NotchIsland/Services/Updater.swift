import AppKit
import SwiftUI

/// Prüft auf GitHub, ob es eine neuere Version gibt (Releases), und installiert sie auf Wunsch:
/// ZIP laden → entpacken → mit derselben Kennung signieren (Freigaben bleiben) → App austauschen → neu starten.
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, installing, failed(String), notConfigured
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?
    private var timer: Timer?
    private var announced: String?

    static let autoKey = "autoUpdateCheck"
    static let repoKey = "updateRepository"

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "besitzer/notch-island" – aus den Einstellungen, sonst aus der Info.plist (beim Bauen gesetzt)
    var repository: String {
        get {
            let s = UserDefaults.standard.string(forKey: Self.repoKey) ?? ""
            if !s.isEmpty { return s }
            let p = Bundle.main.object(forInfoDictionaryKey: "NotchIslandRepository") as? String ?? ""
            return p.contains("__") ? "" : p
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Self.repoKey); objectWillChange.send() }
    }

    /// Nur „besitzer/repo“ mit erlaubten Zeichen – verhindert manipulierte Adressen
    static func isValidRepo(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
    }

    /// Downloads nur von GitHub selbst (inkl. dessen Download-Servern) und nur über HTTPS
    static func isTrustedDownload(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "github.com" || h.hasSuffix(".githubusercontent.com")
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }

    func start() {
        UserDefaults.standard.register(defaults: [Self.autoKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
    }

    private func autoCheck() {
        guard UserDefaults.standard.bool(forKey: Self.autoKey) else { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        let repo = repository
        guard Self.isValidRepo(repo) else { state = .notConfigured; return }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        state = .checking
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NotchIsland-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastCheck = Date()
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state = code == 404 ? .upToDate : .failed(err?.localizedDescription ?? "GitHub antwortet nicht (\(code))")
                    return
                }
                let tag = (obj["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let zip = assets.compactMap { a -> URL? in
                    guard let n = a["name"] as? String, n.lowercased().hasSuffix(".zip"),
                          let s = a["browser_download_url"] as? String, let u = URL(string: s), Self.isTrustedDownload(u) else { return nil }
                    return u
                }.first
                let page = URL(string: obj["html_url"] as? String ?? "") ?? URL(string: "https://github.com/\(repo)/releases")!
                if Self.isNewer(tag, than: self.currentVersion), let zip {
                    let r = Release(version: tag, notes: String((obj["body"] as? String ?? "").prefix(400)), zipURL: zip, pageURL: page)
                    self.state = .available(r)
                    if self.announced != tag {
                        self.announced = tag
                        self.announce(r)
                    }
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func announce(_ r: Release) {
        IslandModel.shared.show(Toast(
            symbol: "arrow.down.circle.fill", tint: .blue, title: "Update verfügbar",
            subtitle: "Notch Island \(r.version) · du hast \(currentVersion)",
            buttons: [ToastButton(title: "Installieren", tint: .blue) { [weak self] in self?.install() }],
            duration: 12))
    }

    // MARK: Installieren

    func install() {
        guard let r = available else { return }
        state = .downloading
        IslandModel.shared.show(Toast(symbol: "arrow.down.circle", tint: .blue, title: "Update wird geladen …", subtitle: r.version, duration: 4))
        URLSession.shared.downloadTask(with: r.zipURL) { [weak self] tmp, resp, err in
            guard let self else { return }
            let finalOK = resp?.url.map(Self.isTrustedDownload) ?? false
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmp, err == nil, finalOK, code == 200 else {
                DispatchQueue.main.async { self.fail("Download fehlgeschlagen") }
                return
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotchIslandUpdate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try? FileManager.default.moveItem(at: tmp, to: zip)
            DispatchQueue.main.async { self.state = .installing }
            DispatchQueue.global(qos: .userInitiated).async { self.prepareAndSwap(zip: zip, work: work) }
        }.resume()
    }

    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private func prepareAndSwap(zip: URL, work: URL) {
        let out = work.appendingPathComponent("x")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]),
              let newApp = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              // Plausibilität: muss wirklich Notch Island sein
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleExecutable"] as? String == "NotchIsland",
              FileManager.default.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/NotchIsland").path),
              let newVersion = info["CFBundleShortVersionString"] as? String,
              Self.isNewer(newVersion, than: currentVersion) else {
            DispatchQueue.main.async { self.fail("Update-Datei ist ungültig oder nicht neuer") }
            return
        }
        // Gleiche Kennung wie die installierte App → Freigaben (Bedienungshilfen …) bleiben erhalten
        let id = Bundle.main.bundleIdentifier ?? "io.github.notchisland"
        _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(id)", newApp.appendingPathComponent("Contents/Info.plist").path])
        let repo = repository
        if Self.isValidRepo(repo) {
            _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :NotchIslandRepository \(repo)", newApp.appendingPathComponent("Contents/Info.plist").path])
        }
        _ = run("/usr/bin/xattr", ["-cr", newApp.path])
        let mcp = newApp.appendingPathComponent("Contents/MacOS/notch-mcp").path
        _ = run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", id + ".mcp", "-r=designated => identifier \"\(id).mcp\"", mcp])
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", id, "-r=designated => identifier \"\(id)\"", newApp.path]) else {
            DispatchQueue.main.async { self.fail("Signieren fehlgeschlagen") }
            return
        }
        // Austausch erst, wenn diese App beendet ist – per kleinem Hilfsskript
        let target = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pfade werden als Argumente übergeben (nicht in den Skripttext eingesetzt) – sicher bei Sonderzeichen
        let script = """
        #!/bin/bash
        PID="$1"; TARGET="$2"; NEW="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && mv "$NEW" "$TARGET"; then rm -rf "$TARGET.old"; else [ -d "$TARGET.old" ] && mv "$TARGET.old" "$TARGET"; fi
        open "$TARGET"
        rm -rf "$WORK"
        """
        let sh = work.appendingPathComponent("swap.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh.path, String(pid), target, newApp.path, work.path]
        do { try p.run() } catch {
            DispatchQueue.main.async { self.fail("Austausch fehlgeschlagen") }
            return
        }
        DispatchQueue.main.async {
            IslandModel.shared.show(Toast(symbol: "checkmark.circle.fill", tint: .green, title: "Update installiert", subtitle: "Notch Island startet neu …", duration: 2))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
        }
    }

    private func fail(_ msg: String) {
        state = .failed(msg)
        IslandModel.shared.show(Toast(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Update fehlgeschlagen", subtitle: msg, duration: 5))
    }
}
