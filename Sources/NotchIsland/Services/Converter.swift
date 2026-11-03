import AppKit
import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Quartz
import AVFoundation

// MARK: - Dateiart erkennen

enum DocKind: Equatable {
    case image, pdf, word, presentation, spreadsheet, text, video, audio, other

    static func of(_ u: URL) -> DocKind {
        let ext = u.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx", "doc", "odt", "pages", "dotx", "docm": return .word
        case "pptx", "ppt", "key", "odp", "pptm": return .presentation
        case "xlsx", "xls", "numbers", "ods", "csv", "xlsm": return .spreadsheet
        case "txt", "rtf", "rtfd", "html", "htm", "md", "markdown": return .text
        case "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts": return .video
        case "mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "caf", "m4b", "ogg": return .audio
        default:
            if let t = UTType(filenameExtension: ext) {
                if t.conforms(to: .image) { return .image }
                if t.conforms(to: .movie) { return .video }
                if t.conforms(to: .audio) { return .audio }
            }
            return .other
        }
    }
}

enum ConvertTarget: String, CaseIterable, Identifiable {
    case pdf, jpeg, png, heic, tiff, docx, txt, rtf, xlsx, csv, mp4, mov, m4a, mp3, wav, aiff
    var id: String { rawValue }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    var icon: String {
        switch self {
        case .mp4, .mov: return "film.fill"
        case .m4a, .mp3, .wav, .aiff: return "music.note"
        case .pdf: return "doc.richtext.fill"
        case .jpeg, .png, .heic, .tiff: return "photo.fill"
        case .docx, .rtf: return "doc.text.fill"
        case .txt: return "text.alignleft"
        case .xlsx, .csv: return "tablecells.fill"
        }
    }
    var tint: Color {
        switch self {
        case .mp4, .mov: return Color(red: 0.75, green: 0.55, blue: 1)
        case .m4a, .mp3, .wav, .aiff: return Color(red: 1, green: 0.55, blue: 0.75)
        case .pdf: return Color(red: 1, green: 0.42, blue: 0.38)
        case .jpeg, .png, .heic, .tiff: return Color(red: 0.4, green: 0.8, blue: 1)
        case .docx, .rtf, .txt: return Color(red: 0.45, green: 0.6, blue: 1)
        case .xlsx, .csv: return Color(red: 0.35, green: 0.85, blue: 0.5)
        }
    }
}

enum Converter {
    static let wordID = "com.microsoft.Word"
    static let pptID = "com.microsoft.Powerpoint"
    static let excelID = "com.microsoft.Excel"
    static let pagesID = "com.apple.iWork.Pages"
    static let numbersID = "com.apple.iWork.Numbers"
    static let keynoteID = "com.apple.iWork.Keynote"

    static func installed(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    /// Passende Ziel-Formate für die gezogenen Dateien.
    static func options(for urls: [URL]) -> [ConvertTarget] {
        guard !urls.isEmpty else { return [] }
        var common: [ConvertTarget]?
        for u in urls {
            let opts = options(for: u)
            common = common.map { c in c.filter { opts.contains($0) } } ?? opts
        }
        return common ?? []
    }

    static func options(for u: URL) -> [ConvertTarget] {
        let ext = u.pathExtension.lowercased()
        switch DocKind.of(u) {
        case .image:
            return [.pdf, .jpeg, .png, .heic, .tiff, .docx].filter { !($0.ext == ext || ($0 == .jpeg && ext == "jpeg") || ($0 == .tiff && ext == "tif")) }
        case .pdf:
            var o: [ConvertTarget] = [.jpeg, .png]
            if installed(wordID) { o.append(.docx) }
            o.append(.txt)
            return o
        case .word:
            var o: [ConvertTarget] = [.pdf, .jpeg, .png]
            if ext != "docx" { o.append(.docx) }
            o += [.txt, .rtf]
            return o
        case .presentation:
            return [.pdf, .jpeg, .png]
        case .spreadsheet:
            var o: [ConvertTarget] = [.pdf, .jpeg]
            if ext != "xlsx" { o.append(.xlsx) }
            if ext != "csv" { o.append(.csv) }
            return o
        case .video:
            return [.mp4, .mov, .m4a, .mp3, .wav].filter { $0.ext != ext && !($0 == .mp4 && ext == "m4v") && ($0 != .mp3 || lame != nil) }
        case .audio:
            return [.mp3, .m4a, .wav, .aiff].filter { $0.ext != ext && !($0 == .aiff && ext == "aif") && ($0 != .mp3 || lame != nil) }
        case .text:
            return [.pdf, .jpeg, .docx] + (ext == "txt" ? [.rtf] : [.txt])
        case .other:
            return []
        }
    }

    // MARK: Ausführen

    static func convert(_ urls: [URL], to target: ConvertTarget) {
        guard !urls.isEmpty else { return }
        showToast(Toast(symbol: "arrow.triangle.2.circlepath", tint: target.tint, title: "Konvertiere nach \(target.title) …",
                        subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Dateien", duration: 2))
        DispatchQueue.global(qos: .userInitiated).async {
            var outputs: [URL] = []
            var errors: [String] = []
            // Mehrere Bilder → ein gemeinsames PDF
            if target == .pdf, urls.count > 1, urls.allSatisfy({ DocKind.of($0) == .image }) {
                let out = FileStash.unique(FileStash.outputDir(near: urls[0]).appendingPathComponent(urls[0].deletingPathExtension().lastPathComponent + ".pdf"))
                if imagesToPDF(urls, out: out) { outputs.append(out) } else { errors.append("PDF") }
            } else if target == .docx, urls.count > 1, urls.allSatisfy({ DocKind.of($0) == .image }) {
                let out = FileStash.unique(FileStash.outputDir(near: urls[0]).appendingPathComponent(urls[0].deletingPathExtension().lastPathComponent + ".docx"))
                do { try imagesToDOCX(urls, out: out); outputs.append(out) } catch { errors.append(error.localizedDescription) }
            } else {
                for u in urls {
                    do { outputs += try convert(u, to: target) }
                    catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
                }
            }
            DevBridge.log("Konvertiert → \(target.title): \(outputs.map(\.lastPathComponent)) Fehler: \(errors)")
            DispatchQueue.main.async {
                if outputs.isEmpty {
                    IslandModel.shared.show(Toast(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Konvertieren fehlgeschlagen",
                                                  subtitle: errors.first, duration: 5))
                    return
                }
                ShelfStore.shared.present(outputs, title: outputs[0].lastPathComponent,
                                          subtitle: (outputs.count == 1 ? "Als \(target.title) gespeichert" : "\(outputs.count) Dateien als \(target.title)") + " · zum Ablegen ziehen",
                                          tint: target.tint)
            }
        }
    }

    struct ConvertError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func convert(_ u: URL, to target: ConvertTarget) throws -> [URL] {
        let dir = FileStash.outputDir(near: u)
        let base = u.deletingPathExtension().lastPathComponent
        let out = FileStash.unique(dir.appendingPathComponent(base + "." + target.ext))
        let kind = DocKind.of(u)

        switch (kind, target) {
        case (.image, .pdf):
            guard imagesToPDF([u], out: out) else { throw ConvertError(message: "Bild konnte nicht gelesen werden") }
            return [out]
        case (.image, .docx):
            try imagesToDOCX([u], out: out)
            return [out]
        case (.word, .jpeg), (.word, .png), (.presentation, .jpeg), (.presentation, .png),
             (.spreadsheet, .jpeg), (.spreadsheet, .png), (.text, .jpeg), (.text, .png):
            // Erst originalgetreu als PDF, dann jede Seite als Bild (300 dpi)
            guard let pdf = try convert(u, to: .pdf).first else { throw ConvertError(message: "PDF-Zwischenschritt fehlgeschlagen") }
            defer { try? FileManager.default.removeItem(at: pdf) }
            return try pdfToImages(pdf, target: target, dir: dir, base: base)
        case (.video, _), (.audio, _):
            try convertMedia(u, to: target, out: out)
            return [out]
        case (.image, _):
            try convertImage(u, to: target, out: out)
            return [out]
        case (.pdf, .jpeg), (.pdf, .png):
            return try pdfToImages(u, target: target, dir: dir, base: base)
        case (.pdf, .txt):
            guard let s = PDFDocument(url: u)?.string else { throw ConvertError(message: "Kein Text im PDF") }
            try s.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case (.pdf, .docx):
            try word(open: u, save: out, format: "format document")
            return [out]

        case (.word, .pdf):
            if installed(wordID), (try? word(open: u, save: out, format: "format PDF")) != nil { return [out] }
            if installed(pagesID) { try iwork(pagesID, open: u, export: out, as: "PDF"); return [out] }
            try printToPDF(u, out: out)
            return [out]
        case (.word, .docx):
            if u.pathExtension.lowercased() == "pages" { try iwork(pagesID, open: u, export: out, as: "Microsoft Word"); return [out] }
            if installed(wordID), (try? word(open: u, save: out, format: "format document")) != nil { return [out] }
            try textutil(u, format: "docx", out: out)
            return [out]
        case (.word, .txt), (.text, .txt):
            try textutil(u, format: "txt", out: out)
            return [out]
        case (.word, .rtf), (.text, .rtf):
            try textutil(u, format: "rtf", out: out)
            return [out]

        case (.text, .pdf):
            try printToPDF(u, out: out)
            return [out]
        case (.text, .docx):
            try textutil(u, format: "docx", out: out)
            return [out]

        case (.presentation, .pdf):
            if u.pathExtension.lowercased() == "key" || !installed(pptID) {
                guard installed(keynoteID) else { throw ConvertError(message: "PowerPoint oder Keynote wird benötigt") }
                try iwork(keynoteID, open: u, export: out, as: "PDF")
                return [out]
            }
            try powerpoint(open: u, out: out)
            return [out]

        case (.spreadsheet, .pdf):
            if installed(numbersID) { try iwork(numbersID, open: u, export: out, as: "PDF"); return [out] }
            throw ConvertError(message: "Numbers wird benötigt")
        case (.spreadsheet, .xlsx):
            try iwork(numbersID, open: u, export: out, as: "Microsoft Excel")
            return [out]
        case (.spreadsheet, .csv):
            try iwork(numbersID, open: u, export: out, as: "CSV")
            return [out]

        default:
            throw ConvertError(message: "\(u.pathExtension.uppercased()) → \(target.title) wird nicht unterstützt")
        }
    }

    // MARK: Bilder

    static func imageUTType(_ t: ConvertTarget) -> CFString {
        switch t {
        case .png: return UTType.png.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        default: return UTType.jpeg.identifier as CFString
        }
    }

    /// Bildformat wechseln – volle Auflösung, Metadaten (EXIF, GPS, Farbprofil) bleiben erhalten.
    static func convertImage(_ u: URL, to t: ConvertTarget, out: URL) throws {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let dst = CGImageDestinationCreateWithURL(out as CFURL, imageUTType(t), 1, nil) else {
            throw ConvertError(message: "Bild konnte nicht gelesen werden")
        }
        var props: [CFString: Any] = [:]
        if t == .jpeg || t == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw ConvertError(message: "Speichern fehlgeschlagen") }
        copyDates(from: u, to: out)
    }

    /// Ein oder mehrere Bilder als PDF (je Bild eine Seite, Bilddaten unverändert eingebettet).
    static func imagesToPDF(_ urls: [URL], out: URL) -> Bool {
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { return false }
        var pages = 0
        for u in urls {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            let dpi = max(72, (props[kCGImagePropertyDPIWidth] as? Double) ?? 144)
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            // Originalbild unverändert zeichnen → JPEG-Daten werden 1:1 übernommen (keine Qualitätsverluste, keine Aufblähung).
            let w = Double(img.width) * 72 / dpi, h = Double(img.height) * 72 / dpi
            let rotated = orientation == 6 || orientation == 8
            var box = CGRect(x: 0, y: 0, width: rotated ? h : w, height: rotated ? w : h)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            switch orientation {
            case 3: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
            case 6: ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)
            case 8: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)
            default: break
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            ctx.endPage()
            pages += 1
        }
        ctx.closePDF()
        return pages > 0
    }

    /// Jede PDF-Seite als Bild in 300 dpi.
    static func pdfToImages(_ u: URL, target: ConvertTarget, dir: URL, base: String) throws -> [URL] {
        guard let doc = CGPDFDocument(u as CFURL), doc.numberOfPages > 0 else { throw ConvertError(message: "PDF konnte nicht gelesen werden") }
        let n = doc.numberOfPages
        var folder = dir
        if n > 1 {
            folder = FileStash.unique(dir.appendingPathComponent(base + " (\(target.title))"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var outs: [URL] = []
        let scale = 300.0 / 72.0
        for i in 1...n {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.cropBox)
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            ctx.drawPDFPage(page)
            guard let img = ctx.makeImage() else { continue }
            let name = n > 1 ? "\(base) – Seite \(i).\(target.ext)" : "\(base).\(target.ext)"
            let out = FileStash.unique(folder.appendingPathComponent(name))
            guard let dst = CGImageDestinationCreateWithURL(out as CFURL, imageUTType(target), 1, nil) else { continue }
            var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]
            if target == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(dst, img, props as CFDictionary)
            if CGImageDestinationFinalize(dst) { outs.append(out) }
        }
        guard !outs.isEmpty else { throw ConvertError(message: "Keine Seite konnte gerendert werden") }
        return n > 1 ? [folder] : outs
    }

    // MARK: Bilder → Word

    /// Bilder unverändert (Originaldaten) in ein Word-Dokument einbetten – je Bild eine Seite, an die Seitenbreite angepasst.
    static func imagesToDOCX(_ urls: [URL], out: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("notch-docx-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        for d in ["_rels", "word/_rels", "word/media"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        var body = "", rels = ""
        var n = 0
        for u in urls {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            var pw = Double(props[kCGImagePropertyPixelWidth] as? Int ?? 1000), ph = Double(props[kCGImagePropertyPixelHeight] as? Int ?? 1000)
            let orient = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if [5, 6, 7, 8].contains(orient) { swap(&pw, &ph) }
            let ext = u.pathExtension.lowercased()
            n += 1
            let media: String
            if ["jpg", "jpeg", "png", "gif"].contains(ext) && orient == 1 {
                media = "image\(n).\(ext == "jpeg" ? "jpg" : ext)"
                try fm.copyItem(at: u, to: tmp.appendingPathComponent("word/media/" + media))
            } else {
                // Word kennt kein HEIC/TIFF – in bester JPEG-Qualität (Ausrichtung angewandt) übernehmen
                media = "image\(n).jpg"
                let dstURL = tmp.appendingPathComponent("word/media/" + media)
                guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(pw, ph))] as CFDictionary),
                      let dst = CGImageDestinationCreateWithURL(dstURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dst)
            }
            // Seite A4 mit Rändern: max. 6,3 × 9,3 Zoll
            let maxW = 6.3 * 914400, maxH = 9.3 * 914400
            var cx = pw * 9525, cy = ph * 9525
            let f = min(1, maxW / cx, maxH / cy)
            cx *= f; cy *= f
            if n > 1 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            body += """
            <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(Int(cx))" cy="\(Int(cy))"/><wp:docPr id="\(n)" name="Bild \(n)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(n)" name="\(media)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImg\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(Int(cx))" cy="\(Int(cy))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
            rels += "<Relationship Id=\"rIdImg\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(media)\"/>"
        }
        guard n > 0 else { throw ConvertError(message: "Keine lesbaren Bilder") }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="png" ContentType="image/png"/><Default Extension="gif" ContentType="image/gif"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
        ]
        for (path, content) in files {
            try content.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func zip(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = tmp
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try zip(["-X", "-q", out.path, "[Content_Types].xml"])
        try zip(["-X", "-q", "-r", out.path, ".", "-x", "[Content_Types].xml"])
        guard fm.fileExists(atPath: out.path) else { throw ConvertError(message: "Word-Datei konnte nicht erstellt werden") }
    }

    // MARK: Audio & Video

    static let lamePaths = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"]
    static var lame: String? { lamePaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func convertMedia(_ u: URL, to t: ConvertTarget, out: URL) throws {
        let isVideo = DocKind.of(u) == .video
        switch t {
        case .mp4, .mov:
            try exportAsset(u, out: out, fileType: t == .mp4 ? .mp4 : .mov, audioOnly: false)
        case .m4a:
            if isVideo { try exportAsset(u, out: out, fileType: .m4a, audioOnly: true) }
            else { try afconvert(u, out: out, args: ["-f", "m4af", "-d", "aac", "-b", "256000", "-q", "127"]) }
        case .wav, .aiff:
            var input = u
            var tmpM4A: URL?
            if isVideo {
                let m = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                try exportAsset(u, out: m, fileType: .m4a, audioOnly: true)
                input = m; tmpM4A = m
            }
            defer { if let tmpM4A { try? FileManager.default.removeItem(at: tmpM4A) } }
            try afconvert(input, out: out, args: t == .wav ? ["-f", "WAVE", "-d", "LEI16"] : ["-f", "AIFF", "-d", "BEI16"])
        case .mp3:
            guard let lame else {
                throw ConvertError(message: "Für MP3 wird „lame“ benötigt (Terminal: brew install lame)")
            }
            // Erst verlustfrei nach WAV, dann MP3 in hoher Qualität (VBR ~190–250 kbit/s)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try convertMedia(u, to: .wav, out: wav)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lame)
            p.arguments = ["-V", "0", "--quiet", wav.path, out.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ConvertError(message: "MP3-Kodierung fehlgeschlagen") }
        default:
            throw ConvertError(message: "Nicht unterstützt")
        }
        copyDates(from: u, to: out)
    }

    /// Video/Audio umpacken – wenn möglich verlustfrei („Passthrough“), sonst in höchster Qualität neu kodieren.
    static func exportAsset(_ u: URL, out: URL, fileType: AVFileType, audioOnly: Bool) throws {
        let asset = AVURLAsset(url: u)
        let presets: [String] = audioOnly ? [AVAssetExportPresetAppleM4A]
            : [AVAssetExportPresetPassthrough, AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        var lastError = "Export nicht möglich"
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(fileType) else { continue }
            try? FileManager.default.removeItem(at: out)
            session.outputURL = out
            session.outputFileType = fileType
            session.shouldOptimizeForNetworkUse = fileType == .mp4
            let sem = DispatchSemaphore(value: 0)
            session.exportAsynchronously { sem.signal() }
            sem.wait()
            if session.status == .completed { return }
            lastError = session.error?.localizedDescription ?? lastError
        }
        throw ConvertError(message: lastError)
    }

    static func afconvert(_ u: URL, out: URL, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = args + [u.path, out.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ConvertError(message: "Audio konnte nicht umgewandelt werden") }
    }

    // MARK: Office & iWork (per AppleScript – originalgetreue Darstellung)

    private static func hfs(_ u: URL) -> String { "(POSIX file \"\(esc(u.path))\" as string)" }
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    private static func runScript(_ src: String) throws {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { throw ConvertError(message: "Skriptfehler") }
        _ = script.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript-Fehler"
            throw ConvertError(message: msg)
        }
    }

    private static func waitForFile(_ u: URL, timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let size = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber, size.intValue > 0 { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// Office-Apps sind „sandboxed“: In ihren eigenen Container dürfen sie immer schreiben – so erscheint
    /// kein „Dateizugriff erteilen“-Dialog. Danach wird die Datei an ihr Ziel verschoben.
    static func officeTemp(_ appID: String, ext: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(appID)/Data/tmp/NotchIsland-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    static func moveFromOffice(_ tmp: URL, to out: URL, appName: String) throws {
        guard waitForFile(tmp) else { throw ConvertError(message: "\(appName) hat keine Datei gespeichert") }
        Thread.sleep(forTimeInterval: 0.5)
        let fm = FileManager.default
        do {
            try fm.copyItem(at: tmp, to: out)
        } catch {
            DevBridge.log("copyItem aus Container fehlgeschlagen: \(error.localizedDescription) – versuche Daten zu lesen")
            let data = try Data(contentsOf: tmp)
            try data.write(to: out)
        }
        try? fm.removeItem(at: tmp)
    }

    /// Office ist „sandboxed“ und fragt pro Ordner einmal nach Schreibzugriff.
    static func officeHint(_ app: String) {
        let key = "officeHint-" + app
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showToast(Toast(symbol: "folder.badge.questionmark", tint: .orange, title: "\(app) fragt evtl. nach Ordnerzugriff",
                        subtitle: "„Auswählen…“ → am besten deinen Benutzerordner wählen", duration: 9))
    }

    static func word(open u: URL, save out: URL, format: String) throws {
        officeHint("Word")
        let tmp = out
        let src = """
        with timeout of 300 seconds
            tell application id "\(wordID)"
                activate
                try
                    set display alerts to alerts none
                end try
                open (POSIX file "\(esc(u.path))")
                delay 1
                set d to active document
                save as d file name \(hfs(tmp)) file format \(format)
                close d saving no
            end tell
        end timeout
        """
        try runScript(src)
        guard waitForFile(tmp) else { throw ConvertError(message: "Word hat keine Datei gespeichert") }
        copyDates(from: u, to: out)
    }

    static func powerpoint(open u: URL, out: URL) throws {
        officeHint("PowerPoint")
        let tmp = out
        let src = """
        with timeout of 300 seconds
            tell application id "\(pptID)"
                activate
                open (POSIX file "\(esc(u.path))")
                delay 1
                set p to active presentation
                save p in \(hfs(tmp)) as save as PDF
                close p saving no
            end tell
        end timeout
        """
        try runScript(src)
        guard waitForFile(tmp) else { throw ConvertError(message: "PowerPoint hat keine Datei gespeichert") }
        copyDates(from: u, to: out)
    }

    static func iwork(_ app: String, open u: URL, export out: URL, as format: String) throws {
        let src = """
        with timeout of 300 seconds
            tell application id "\(app)"
                set d to open POSIX file "\(esc(u.path))"
                export d to POSIX file "\(esc(out.path))" as \(format)
                close d saving no
            end tell
        end timeout
        """
        try runScript(src)
        guard waitForFile(out) else { throw ConvertError(message: "Export fehlgeschlagen") }
        copyDates(from: u, to: out)
    }

    // MARK: Text

    static func textutil(_ u: URL, format: String, out: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", format, "-output", out.path, u.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ConvertError(message: "textutil konnte die Datei nicht umwandeln") }
        copyDates(from: u, to: out)
    }

    /// Text/RTF/HTML/DOCX ohne Office als PDF setzen (A4).
    static func printToPDF(_ u: URL, out: URL) throws {
        var result: Error?
        DispatchQueue.main.sync {
            do {
                let attr = try NSAttributedString(url: u, options: [:], documentAttributes: nil)
                let info = NSPrintInfo()
                info.paperSize = NSSize(width: 595.2, height: 841.8)
                info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
                let width = info.paperSize.width - info.leftMargin - info.rightMargin
                let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
                tv.textStorage?.setAttributedString(attr)
                tv.sizeToFit()
                let op = NSPrintOperation(view: tv, printInfo: info)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                if !op.run() { result = ConvertError(message: "PDF konnte nicht erstellt werden") }
            } catch { result = error }
        }
        if let result { throw result }
        copyDates(from: u, to: out)
    }

    // MARK: Metadaten

    static func copyDates(from src: URL, to dst: URL) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let c = a[.creationDate] { keep[.creationDate] = c }
        try? FileManager.default.setAttributes(keep, ofItemAtPath: dst.path)
    }
}

// MARK: - Verkleinern je nach Dateityp

enum Compressor {
    struct Result { let url: URL; let before: Int64; let after: Int64 }

    static func size(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        showToast(Toast(symbol: "arrow.down.right.and.arrow.up.left", tint: .pink, title: "Verkleinere …",
                        subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Dateien", duration: 2))
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [Result] = []
            var notSmaller: [String] = []
            var failed: [String] = []
            for u in urls {
                do {
                    if let r = try compress(u) { results.append(r) } else { notSmaller.append(u.lastPathComponent) }
                } catch {
                    failed.append(u.lastPathComponent + ": " + error.localizedDescription)
                }
            }
            DevBridge.log("Verkleinert: \(results.map { "\($0.url.lastPathComponent) \($0.before)→\($0.after)" }) unverändert: \(notSmaller) Fehler: \(failed)")
            DispatchQueue.main.async {
                guard !results.isEmpty else {
                    IslandModel.shared.show(Toast(symbol: "checkmark.seal.fill", tint: .orange,
                                                  title: failed.isEmpty ? "Bereits optimal komprimiert" : "Verkleinern fehlgeschlagen",
                                                  subtitle: failed.first ?? notSmaller.first, duration: 4))
                    return
                }
                let before = results.reduce(0) { $0 + $1.before }, after = results.reduce(0) { $0 + $1.after }
                let pct = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
                ShelfStore.shared.present(results.map(\.url), title: results[0].url.lastPathComponent,
                                          subtitle: "−\(pct) % · \(formatBytes(before)) → \(formatBytes(after)) · zum Ablegen ziehen",
                                          tint: .pink)
            }
        }
    }

    /// Liefert nil, wenn die Datei nicht kleiner wurde (dann wird nichts gespeichert).
    static func compress(_ u: URL) throws -> Result? {
        let dir = FileStash.outputDir(near: u)
        let ext = u.pathExtension
        let out = FileStash.unique(dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + "-klein." + ext))
        let before = size(u)
        switch DocKind.of(u) {
        case .image:
            try compressImage(u, out: out, maxPixel: 3000)
        case .pdf:
            guard let doc = PDFDocument(url: u) else { throw Converter.ConvertError(message: "PDF nicht lesbar") }
            // Alle Seiten, Text und Vektoren bleiben – nur eingebettete Bilder werden optimiert
            // Stufenweise: erst 200 dpi / hohe Qualität, falls das kaum etwas bringt 150 dpi.
            // Text, Vektoren, Links und alle Seiten bleiben unverändert – nur eingebettete Bilder werden neu gerechnet.
            var ok = false
            for (dpi, q) in [(200, 0.8), (150, 0.72)] {
                guard let filter = pdfFilter(dpi: dpi, quality: q) else { continue }
                ok = doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
                if ok, size(out) < before * 85 / 100 { break }
            }
            guard ok else { throw Converter.ConvertError(message: "PDF konnte nicht gespeichert werden") }
            if PDFDocument(url: out)?.pageCount != doc.pageCount {
                try? FileManager.default.removeItem(at: out)
                throw Converter.ConvertError(message: "Seitenzahl stimmte nicht – Original behalten")
            }
        case .word, .presentation, .spreadsheet:
            guard ["docx", "pptx", "xlsx", "docm", "pptm", "xlsm"].contains(ext.lowercased()) else { return try zipFallback(u, dir: dir, before: before) }
            try compressOOXML(u, out: out)
        default:
            return try zipFallback(u, dir: dir, before: before)
        }
        let after = size(out)
        if after <= 0 || after >= before * 97 / 100 {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        Converter.copyDates(from: u, to: out)
        return Result(url: out, before: before, after: after)
    }

    /// Quartz-Filter wie in Vorschau › „Dateigröße reduzieren“, aber mit guter Qualität.
    static func pdfFilter(dpi: Int, quality: Double) -> QuartzFilter? {
        let dict: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Notch Island \(dpi) dpi",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleFactor": 0.0,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 0,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
        ]
        let url = FileStash.base.appendingPathComponent("filter-\(dpi).qfilter")
        guard (dict as NSDictionary).write(to: url, atomically: true) else { return nil }
        return QuartzFilter(url: url)
    }

    /// Unbekannter Typ: als ZIP packen (verlustfrei)
    static func zipFallback(_ u: URL, dir: URL, before: Int64) throws -> Result? {
        do {
            let zipOut = FileStash.unique(dir.appendingPathComponent(u.lastPathComponent + ".zip"))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", u.path, zipOut.path]
            try p.run(); p.waitUntilExit()
            let after = size(zipOut)
            if after >= before { try? FileManager.default.removeItem(at: zipOut); return nil }
            return Result(url: zipOut, before: before, after: after)
        }
    }

    /// Gleiches Format behalten, große Bilder auf max. 3000 px, verlustarme Qualität, Metadaten bleiben.
    static func compressImage(_ u: URL, out: URL, maxPixel: Int) throws {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let type = CGImageSourceGetType(src),
              let dst = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw Converter.ConvertError(message: "Bildformat wird nicht unterstützt")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        if max(w, h) > maxPixel { opts[kCGImageDestinationImageMaxPixelSize] = maxPixel }
        CGImageDestinationAddImageFromSource(dst, src, 0, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw Converter.ConvertError(message: "Speichern fehlgeschlagen") }
    }

    /// Word/PowerPoint/Excel: eingebettete Bilder optimieren, alles andere (Text, Seiten, Folien) bleibt unverändert.
    static func compressOOXML(_ u: URL, out: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("notch-ooxml-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", u.path, tmp.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw Converter.ConvertError(message: "Datei konnte nicht entpackt werden") }

        for media in ["word/media", "ppt/media", "xl/media"] {
            let mdir = tmp.appendingPathComponent(media)
            guard let files = try? fm.contentsOfDirectory(at: mdir, includingPropertiesForKeys: nil) else { continue }
            for f in files where ["jpg", "jpeg", "png", "tif", "tiff"].contains(f.pathExtension.lowercased()) {
                let opt = f.deletingLastPathComponent().appendingPathComponent("opt-" + f.lastPathComponent)
                if (try? compressImage(f, out: opt, maxPixel: 2400)) != nil, size(opt) > 0, size(opt) < size(f) {
                    try? fm.removeItem(at: f)
                    try? fm.moveItem(at: opt, to: f)
                } else {
                    try? fm.removeItem(at: opt)
                }
            }
        }
        // Neu packen ([Content_Types].xml zuerst)
        func zip(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = tmp
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try zip(["-X", "-9", "-q", out.path, "[Content_Types].xml"])
        try zip(["-X", "-9", "-q", "-r", out.path, ".", "-x", "[Content_Types].xml"])
    }
}
