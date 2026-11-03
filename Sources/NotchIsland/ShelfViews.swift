import SwiftUI
import AppKit

struct ShelfView: View {
    @ObservedObject var shelf = ShelfStore.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf.items.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(targeted ? 0.08 : 0.03)))
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .symbolEffect(.bounce, value: targeted)
                        Text(tr("Dateien, Bilder, Links oder Text hierher ziehen"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(tr("Beim Ziehen auf die Notch erscheinen Aktionen: AirDrop, ZIP, Text erkennen …"))
                            .font(.system(size: 11)).foregroundStyle(Color.dim)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfItemView(item: item)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: shelf.items)
                }
                .frame(height: 104)
                HStack(spacing: 6) {
                    Text(shelf.items.count == 1 ? tr("1 Objekt") : "\(shelf.items.count) Objekte")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.dim)
                    Text(tr("· Herausziehen zum Ablegen")).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.35))
                    Spacer(minLength: 0)
                    PillButton(title: "AirDrop", symbol: "dot.radiowaves.up.forward") { FileOps.airdrop(shelf.urls) }
                    PillButton(title: tr("Teilen"), symbol: "square.and.arrow.up") { FileOps.share(shelf.urls) }
                    PillButton(title: "ZIP", symbol: "doc.zipper") { FileOps.zip(shelf.urls) }
                    PillButton(title: tr("Leeren"), symbol: "trash", tint: Color.red.opacity(0.25), fg: .red) {
                        withAnimation { shelf.clear() }
                    }
                }
            }
        }
        .onDrop(of: DropLoader.types, isTargeted: $targeted) { providers in
            DropLoader.load(providers) { urls in ShelfStore.shared.importCopies(urls) }
            return true
        }
    }
}

struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var shelf = ShelfStore.shared
    @State private var hover = false
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 28, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(shelf.highlighted.contains(item.path) ? Color.blue.opacity(0.22) : Color.white.opacity(hover ? 0.1 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.blue.opacity(shelf.highlighted.contains(item.path) ? 0.9 : 0), lineWidth: 1.5))
        .overlay(alignment: .topLeading) {
            if shelf.highlighted.contains(item.path) {
                Text("NEU").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.blue)).offset(x: 3, y: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation { ShelfStore.shared.remove(item.id) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.35))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag {
            FileDrag.provider(item.url)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button(tr("Öffnen")) { NSWorkspace.shared.open(item.url) }
            Button(tr("Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(tr("Per AirDrop senden")) { FileOps.airdrop([item.url]) }
            Button(tr("Teilen …")) { FileOps.share([item.url]) }
            Button(tr("Pfad kopieren")) { FileOps.copyPaths([item.url]) }
            Button(tr("Text erkennen")) { FileOps.recognizeText([item.url]) }
            Button(tr("Verkleinern")) { Compressor.compress([item.url]) }
            let conv = Converter.options(for: [item.url])
            if !conv.isEmpty {
                Menu(tr("Konvertieren in")) {
                    ForEach(conv) { t in Button(t.title) { Converter.convert([item.url], to: t) } }
                }
            }
            Divider()
            Button(tr("Aus Ablage entfernen")) { ShelfStore.shared.remove(item.id) }
        }
        .help(item.name)
        .task(id: item.id) { thumb = await Thumbnailer.thumbnail(for: item.url) }
    }
}

// MARK: - Aktionen beim Ziehen (wie Dropzone)

struct DropZoneView: View {
    @ObservedObject var model = IslandModel.shared
    private let actions = DropActions.all()

    var body: some View {
        let conversions = Converter.options(for: model.dragURLs)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: tr("Loslassen zum Ausführen"))
                if let kind = kindLabel { Text("· " + kind).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5)) }
                Spacer()
                Text("⌥ gedrückt = verschieben statt kopieren")
                    .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.4))
            }
            HStack(spacing: 7) {
                ForEach(actions) { a in DropTile(action: a) }
            }
            .frame(height: 104)
            if !conversions.isEmpty {
                SectionLabel(text: tr("Konvertieren in"))
                HStack(spacing: 7) {
                    ForEach(conversions) { t in
                        DropTile(action: DropAction(id: "conv-" + t.rawValue, title: t.title, icon: t.icon, tint: t.tint) { urls, _ in
                            Converter.convert(urls, to: t)
                        }, compact: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 50)
            }
        }
    }

    private var kindLabel: String? {
        let urls = model.dragURLs
        guard !urls.isEmpty else { return nil }
        let exts = Set(urls.map { $0.pathExtension.uppercased() }).filter { !$0.isEmpty }
        let what = exts.isEmpty ? tr("Ordner") : exts.sorted().joined(separator: ", ")
        return urls.count == 1 ? "\(what)-Datei" : "\(urls.count) Dateien (\(what))"
    }
}

struct DropTile: View {
    let action: DropAction
    var compact = false
    @State private var targeted = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 6) {
                    Image(systemName: action.icon).font(.system(size: 13, weight: .semibold))
                    Text(action.title).font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: action.icon)
                        .font(.system(size: 21, weight: .medium))
                        .symbolEffect(.bounce, value: targeted)
                    Text(action.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .foregroundStyle(targeted ? Color.black : Color.white)
        .padding(.horizontal, compact ? 0 : 4)
        .frame(maxWidth: compact ? nil : .infinity, maxHeight: .infinity)
        .frame(minWidth: compact ? 92 : nil)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(targeted ? action.tint : Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0 : 0.2), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .scaleEffect(targeted ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: targeted)
        .onChange(of: targeted) { _, now in if now { haptic() } }
        .onDrop(of: DropLoader.types, isTargeted: $targeted) { providers in
            let move = NSEvent.modifierFlags.contains(.option)
            DropLoader.load(providers) { urls in
                guard !urls.isEmpty else { return }
                action.run(urls, move)
            }
            return true
        }
    }
}
