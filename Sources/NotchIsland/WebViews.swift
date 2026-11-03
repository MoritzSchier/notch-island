import SwiftUI
import AppKit

// MARK: - Websites

struct WebTabView: View {
    @ObservedObject var web = WebFavorites.shared
    @ObservedObject var model = IslandModel.shared
    @State private var urlText = ""
    @State private var titleText = ""
    @FocusState private var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: WebFavorites.perRow)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if web.adding {
                addForm
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(web.items.prefix(web.adding ? WebFavorites.perRow - 1 : 2 * WebFavorites.perRow - 1)) { f in
                    WebTile(fav: f)
                }
                if !web.adding {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { web.adding = true }
                        model.hostView?.window?.makeKey()
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])))
                            Text("Hinzufügen").font(.system(size: 10.5)).foregroundStyle(Color.dim)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var addForm: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(Color.dim)
            TextField("Adresse, z. B. moodle.uni.de", text: $urlText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
                .frame(minWidth: 180)
            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dim)
            }
            .buttonStyle(PressableStyle())
            .help("Adresse aus der Zwischenablage einsetzen")
            TextField("Name (optional)", text: $titleText)
                .textFieldStyle(.plain)
                .onSubmit(save)
                .frame(width: 120)
            PillButton(title: "Aktuelle Seite", symbol: "safari") {
                web.addCurrentBrowserTab()
                close()
            }
            PillButton(title: "Hinzufügen", tint: .blue) { save() }
            CircleButton(symbol: "xmark", size: 24) { close() }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardFill))
        .onAppear {
            // Steht ein Link in der Zwischenablage, gleich vorschlagen
            if urlText.isEmpty, let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.count < 500, WebFavorites.normalize(s) != nil, s.contains(".") {
                urlText = s
            }
            model.hostView?.window?.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private func save() {
        if web.add(urlText, title: titleText) { close() }
    }

    private func close() {
        urlText = ""
        titleText = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { web.adding = false }

    }
}

struct WebTile: View {
    let fav: WebFavorite
    @ObservedObject var web = WebFavorites.shared
    @State private var hover = false

    var body: some View {
        Button { web.open(fav) } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(hover ? 0.16 : 0.09))
                    if let img = web.icons[fav.host] {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text(String(fav.title.prefix(1))).font(.system(size: 19, weight: .bold, design: .rounded))
                    }
                }
                .frame(width: 46, height: 46)
                .scaleEffect(hover ? 1.06 : 1)
                Text(fav.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation { web.remove(fav.id) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color(white: 0.35))
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: -3)
            }
        }
        .contextMenu {
            Button("Öffnen") { web.open(fav) }
            Button("Adresse kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fav.url, forType: .string)
            }
            Button("Nach links") { web.move(fav.id, by: -1) }
            Button("Nach rechts") { web.move(fav.id, by: 1) }
            Divider()
            Button("Entfernen") { web.remove(fav.id) }
        }
        .help(fav.url)
    }
}

