import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Vision
import PDFKit
import ImageIO

struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var name: String
    var added = Date()
    var owned = false
    /// Ordner, aus dem die Datei ursprünglich kam (für Ergebnisse von Konvertieren/Verkleinern)
    var originDir: String? = nil
    var url: URL { URL(fileURLWithPath: path) }
}

enum FileStash {
    static let base: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let shelfDir: URL = {
        let u = base.appendingPathComponent("Ablage", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return f.string(from: Date())
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }

    static func writeText(_ s: String) -> URL? {
        let first = s.split(separator: "\n").first.map(String.init) ?? tr("Text")
        let clean = String(first.prefix(40)).replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let u = unique(shelfDir.appendingPathComponent((clean.isEmpty ? "Text" : clean) + ".txt"))
        return (try? s.write(to: u, atomically: true, encoding: .utf8)) != nil ? u : nil
    }

    static func writeImage(_ data: Data) -> URL? {
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let u = unique(shelfDir.appendingPathComponent("Bild \(stamp()).png"))
        return (try? png.write(to: u)) != nil ? u : nil
    }

    static func writeWebloc(_ link: URL) -> URL? {
        let title = (link.host ?? "Link").replacingOccurrences(of: "www.", with: "")
        let u = unique(shelfDir.appendingPathComponent(title + ".webloc"))
        let dict: NSDictionary = ["URL": link.absoluteString]
        return dict.write(to: u, atomically: true) ? u : nil
    }

    /// Zielordner für erzeugte Dateien: neben dem Original, falls beschreibbar.
    /// Ursprungsordner von Dateien in der Ablage (Pfad der Kopie → Ordner des Originals)
    private static let originLock = NSLock()
    private static var origins: [String: String] = [:]
    static func setOrigin(_ dir: String?, for path: String) {
        originLock.lock(); origins[path] = dir; originLock.unlock()
    }
    static func origin(of path: String) -> String? {
        originLock.lock(); defer { originLock.unlock() }
        return origins[path]
    }

    /// Zielordner für erzeugte Dateien: der Ordner, in dem die Datei „wirklich“ liegt
    /// (bei Kopien in der Ablage: der Ordner des Originals).
    static func outputDir(near url: URL) -> URL {
        var parent = url.deletingLastPathComponent()
        if url.path.hasPrefix(shelfDir.path), let o = origin(of: url.path),
           FileManager.default.fileExists(atPath: o) {
            parent = URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.isWritableFile(atPath: parent.path) ? parent : shelfDir
    }
}

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published private(set) var items: [ShelfItem] = []
    private let file = FileStash.base.appendingPathComponent("ablage.json")

    var urls: [URL] { items.map(\.url) }

    init() {
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([ShelfItem].self, from: d) {
            items = list.filter { FileManager.default.fileExists(atPath: $0.path) }
            for it in items { FileStash.setOrigin(it.originDir, for: it.path) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file, options: .atomic) }
    }

    /// Neueste Objekte stehen links.
    func add(_ urls: [URL], origins: [String: String] = [:]) {
        var added = 0
        for u in urls.reversed() {
            if let i = items.firstIndex(where: { $0.path == u.path }) {
                var it = items.remove(at: i)
                it.added = Date()
                items.insert(it, at: 0)
                continue
            }
            let item = ShelfItem(path: u.path, name: u.lastPathComponent, owned: u.path.hasPrefix(FileStash.shelfDir.path),
                                 originDir: origins[u.path])
            FileStash.setOrigin(item.originDir, for: item.path)
            items.insert(item, at: 0)
            added += 1
        }
        let maxItems = max(10, UserDefaults.standard.integer(forKey: Opt.shelfMax))
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        save()
        IslandModel.shared.tab = .shelf
        if added > 0 && !IslandModel.shared.isExpanded {
            IslandModel.shared.show(Toast(symbol: "tray.and.arrow.down.fill", tint: .blue,
                                          title: added == 1 ? tr("In Ablage gelegt") : "\(added) Objekte abgelegt",
                                          subtitle: urls.first?.lastPathComponent, duration: 2.2))
        }
    }

    /// Dateien wirklich in die Ablage kopieren – Name, Datum, Tags und übrige Metadaten bleiben erhalten
    /// (auf APFS als platzsparender Klon). Das Original bleibt unangetastet.
    /// Gerade erzeugte Dateien – werden in der Ablage hervorgehoben
    @Published private(set) var highlighted: Set<String> = []

    /// Ergebnis (Konvertieren, Verkleinern, ZIP …) direkt zeigen: Ablage öffnet sich mit der neuen Datei ganz links,
    /// bleibt mind. 5 Sekunden offen (oder bis woanders hingeklickt wird) – zum direkten Weiterziehen.
    /// Ergebnis (Konvertieren, Verkleinern, ZIP …) als einzelnes Dokument in der Notch zeigen –
    /// 5 Sekunden lang (länger, solange die Maus darauf ist) oder bis woanders hingeklickt wird.
    /// Von dort lässt es sich direkt an sein Ziel ziehen. In der Ablage landet es zusätzlich so oder so.
    func present(_ urls: [URL], title: String, subtitle: String? = nil, tint: Color = .blue) {
        guard let first = urls.first else { return }
        importCopies(urls) { copies in
            self.highlighted = Set(copies.map(\.path))
            let model = IslandModel.shared
            model.collapse()
            var t = Toast(image: NSWorkspace.shared.icon(forFile: first.path), tint: tint, title: title,
                          subtitle: subtitle ?? first.lastPathComponent, duration: 7,
                          onTap: { NSWorkspace.shared.activateFileViewerSelecting(urls) })
            t.file = first
            model.show(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation(.easeOut(duration: 0.4)) { self.highlighted.subtract(copies.map(\.path)) }
            }
        }
    }

    func importCopies(_ urls: [URL], completion: (([URL]) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var copies: [URL] = []
            var origins: [String: String] = [:]
            for u in urls {
                if u.path.hasPrefix(FileStash.shelfDir.path) { copies.append(u); continue }
                let dest = FileStash.unique(FileStash.shelfDir.appendingPathComponent(u.lastPathComponent))
                do {
                    try fm.copyItem(at: u, to: dest)
                    copies.append(dest)
                    origins[dest.path] = u.deletingLastPathComponent().path
                } catch {
                    DevBridge.log("Kopieren fehlgeschlagen: \(u.path) – \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.add(copies, origins: origins)
                completion?(copies)
            }
        }
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: i)
        if it.owned { try? FileManager.default.removeItem(at: it.url) }
        save()
    }

    func clear() {
        for it in items where it.owned { try? FileManager.default.removeItem(at: it.url) }
        items = []
        save()
    }
}

// MARK: - Gezogene Inhalte laden

enum DropLoader {
    static let types: [UTType] = [.fileURL, .url, .image, .pdf, .data, .plainText, .text]

    /// Finder liefert oft "file:///.file/id=…"-Verweise – in einen echten Pfad (mit Dateinamen) auflösen.
    static func resolve(_ u: URL) -> URL {
        guard u.isFileURL else { return u }
        return ((u as NSURL).filePathURL ?? u).standardizedFileURL
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ u: URL?) {
            guard let u else { return }
            lock.lock(); urls.append(u); lock.unlock()
        }
        for p in providers {
            group.enter()
            // Ein Dateityp (kein reiner Text/Link), den der Absender als echte Datei liefern kann – z. B. Bild aus Safari, PDF aus Mail
            let fileType = p.registeredTypeIdentifiers.first { id in
                guard let t = UTType(id) else { return false }
                return t.conforms(to: .data) && !t.conforms(to: .text) && !t.conforms(to: .url) && t != .data
            }
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { add(resolve(u)) }
                    else if let u = item as? URL { add(resolve(u)) }
                    group.leave()
                }
            } else if let fileType {
                // Originaldatei samt Namen übernehmen (keine Umwandlung)
                let suggested = p.suggestedName
                _ = p.loadFileRepresentation(forTypeIdentifier: fileType) { tmp, _ in
                    defer { group.leave() }
                    guard let tmp else { return }
                    let ext = tmp.pathExtension.isEmpty ? (UTType(fileType)?.preferredFilenameExtension ?? "") : tmp.pathExtension
                    var name = suggested ?? tmp.deletingPathExtension().lastPathComponent
                    if !ext.isEmpty && !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
                    let dest = FileStash.unique(FileStash.shelfDir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-")))
                    if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { add(dest) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    var link: URL?
                    if let d = item as? Data { link = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { link = u }
                    if let link { add(link.isFileURL ? resolve(link) : FileStash.writeWebloc(link)) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? String { add(FileStash.writeText(s)) }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

/// Herausziehen: als echte Datei-URL übergeben → Finder & Co. kopieren die Originaldatei
/// mit Namen, Datum, Tags und allen übrigen Metadaten (statt eine namenlose Kopie zu erzeugen).
enum FileDrag {
    static func provider(_ url: URL) -> NSItemProvider {
        let p = NSItemProvider(object: url as NSURL)
        p.suggestedName = url.lastPathComponent
        return p
    }
}

enum Thumbnailer {
    static func thumbnail(for url: URL) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 108, height: 108), scale: 2,
                                               representationTypes: .thumbnail)
        return await withCheckedContinuation { c in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                c.resume(returning: rep?.nsImage)
            }
        }
    }
}

// MARK: - Aktionen

struct DropAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    let run: ([URL], Bool) -> Void
}

enum DropActions {
    static func all() -> [DropAction] {
        var a: [DropAction] = [
            DropAction(id: "shelf", title: tr("Ablage"), icon: "tray.and.arrow.down.fill", tint: .white) { urls, _ in
                ShelfStore.shared.importCopies(urls)
            },
            DropAction(id: "airdrop", title: "AirDrop", icon: "dot.radiowaves.up.forward", tint: Color(red: 0.35, green: 0.7, blue: 1)) { urls, _ in
                FileOps.airdrop(urls)
            },
            DropAction(id: "share", title: tr("Teilen"), icon: "square.and.arrow.up", tint: Color(red: 0.4, green: 0.85, blue: 0.6)) { urls, _ in
                FileOps.share(urls)
            },
            DropAction(id: "zip", title: "ZIP", icon: "doc.zipper", tint: .yellow) { urls, _ in
                FileOps.zip(urls)
            },
            DropAction(id: "ocr", title: tr("Text erkennen"), icon: "text.viewfinder", tint: .mint) { urls, _ in
                FileOps.recognizeText(urls)
            },
            DropAction(id: "compress", title: tr("Verkleinern"), icon: "arrow.down.right.and.arrow.up.left", tint: .pink) { urls, _ in
                Compressor.compress(urls)
            },
            DropAction(id: "downloads", title: tr("Downloads"), icon: "arrow.down.circle.fill", tint: .blue) { urls, move in
                FileOps.copy(urls, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"), move: move)
            },
            DropAction(id: "path", title: tr("Pfad kopieren"), icon: "link", tint: .gray) { urls, _ in
                FileOps.copyPaths(urls)
            },
        ]
        for path in Prefs.folders.prefix(3) {
            let u = URL(fileURLWithPath: path)
            a.append(DropAction(id: "folder:" + path, title: u.lastPathComponent, icon: "folder.fill", tint: .cyan) { urls, move in
                FileOps.copy(urls, to: u, move: move)
            })
        }
        return a
    }
}

/// Gibt die Insel wieder frei, sobald im Teilen-Menü etwas gewählt (oder es geschlossen) wurde.
final class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharePickerDelegate()
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { IslandModel.shared.release("share") }
    }
}

enum FileOps {
    static func airdrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    static func share(_ urls: [URL]) {
        guard !urls.isEmpty, let v = IslandModel.shared.hostView, let w = v.window else { return }
        IslandModel.shared.hold("share", max: 15)
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = SharePickerDelegate.shared
        let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: v, preferredEdge: .minY)
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        showToast(Toast(symbol: "link", tint: .gray, title: tr("Pfad kopiert"), subtitle: urls.first?.path, duration: 2))
    }

    static func copy(_ urls: [URL], to folder: URL, move: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var ok: [URL] = []
            for u in urls {
                let dest = FileStash.unique(folder.appendingPathComponent(u.lastPathComponent))
                do {
                    if move { try fm.moveItem(at: u, to: dest) } else { try fm.copyItem(at: u, to: dest) }
                    ok.append(dest)
                } catch {}
            }
            let n = ok.count
            showToast(Toast(symbol: move ? "arrow.right.doc.on.clipboard" : "doc.on.doc.fill", tint: .cyan,
                            title: n == 0 ? tr("Fehlgeschlagen") : "\(n) \(n == 1 ? "Objekt" : "Objekte") \(move ? "verschoben" : "kopiert")",
                            subtitle: tr("nach \(folder.lastPathComponent)"), trailing: n > 0 ? .check : .none, duration: 2.5,
                            onTap: { if !ok.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(ok) } }))
        }
    }

    static func zip(_ urls: [URL]) {
        guard let first = urls.first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let outDir = FileStash.outputDir(near: first)
            let baseName = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : tr("Archiv")
            let dest = FileStash.unique(outDir.appendingPathComponent(baseName + ".zip"))
            let p = Process()
            if urls.count == 1 {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path]
            } else {
                let parent = first.deletingLastPathComponent()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = parent
                // Relative Namen mit "./" beginnen: eine Datei namens "-TT=…" darf zip nicht als Option lesen
                p.arguments = ["-r", "-q", "-y", dest.path] + urls.map { u in
                    u.path.hasPrefix(parent.path + "/") ? "./" + String(u.path.dropFirst(parent.path.count + 1)) : u.path
                }
            }
            var success = false
            do {
                try p.run()
                p.waitUntilExit()
                success = p.terminationStatus == 0
            } catch {}
            DispatchQueue.main.async {
                if success {
                    ShelfStore.shared.present([dest], title: dest.lastPathComponent,
                                              subtitle: tr("ZIP erstellt · zum Ablegen ziehen"), tint: .yellow)
                } else {
                    IslandModel.shared.show(Toast(symbol: "exclamationmark.triangle.fill", tint: .red, title: tr("ZIP fehlgeschlagen"), duration: 3))
                }
            }
        }
    }

    static func recognizeText(_ urls: [URL]) {
        showToast(Toast(symbol: "text.viewfinder", tint: .mint, title: tr("Text wird erkannt …"), duration: 1.5))
        DispatchQueue.global(qos: .userInitiated).async {
            var texts: [String] = []
            for u in urls {
                if u.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: u), let s = doc.string,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    texts.append(s)
                    continue
                }
                if ["txt", "md", "csv", "json"].contains(u.pathExtension.lowercased()), let s = try? String(contentsOf: u, encoding: .utf8) {
                    texts.append(s)
                    continue
                }
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.recognitionLanguages = ["de-DE", "en-US"]
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                let t = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                if !t.isEmpty { texts.append(t) }
            }
            DispatchQueue.main.async {
                guard !texts.isEmpty else {
                    IslandModel.shared.show(Toast(symbol: "text.magnifyingglass", tint: .orange, title: tr("Kein Text gefunden"), duration: 2.5))
                    return
                }
                let all = texts.joined(separator: "\n\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(all, forType: .string)
                IslandModel.shared.show(Toast(symbol: "text.viewfinder", tint: .mint, title: tr("Text kopiert"),
                                              subtitle: tr("\(all.count) Zeichen in der Zwischenablage"), trailing: .check, duration: 3))
            }
        }
    }

    static func resizeImages(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [URL] = []
            for u in urls {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { continue }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1920,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                      let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
                else { continue }
                let dest = FileStash.unique(FileStash.outputDir(near: u)
                    .appendingPathComponent(u.deletingPathExtension().lastPathComponent + "-klein.jpg"))
                if (try? data.write(to: dest)) != nil { out.append(dest) }
            }
            DispatchQueue.main.async {
                if out.isEmpty {
                    IslandModel.shared.show(Toast(symbol: "photo", tint: .orange, title: tr("Keine Bilder gefunden"), duration: 2.5))
                } else {
                    ShelfStore.shared.present(out, title: out[0].lastPathComponent, subtitle: tr("Verkleinert · zum Ablegen ziehen"), tint: .pink)
                }
            }
        }
    }
}
