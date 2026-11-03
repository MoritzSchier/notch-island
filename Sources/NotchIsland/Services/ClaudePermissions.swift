import AppKit
import SwiftUI
import ApplicationServices

/// Eine Erlaubnis-Anfrage aus der Claude-App ("Einmal erlauben", "Immer erlauben", "Ablehnen" …),
/// gespiegelt in die Notch. Die Knöpfe drücken über die Bedienungshilfen exakt die Knöpfe in Claude.
struct PermissionPrompt: Equatable {
    enum Kind { case permission, question }
    struct Option: Identifiable, Equatable {
        enum Role { case allow, always, deny, other }
        let id: Int
        let label: String
        let role: Role
        var detail: String = ""
        var checked = false
    }
    var kind: Kind = .permission
    let key: String
    let title: String
    let detail: String
    let options: [Option]
    /// Bei Rückfragen: Seite x von y (mehrere Fragen nacheinander)
    var progress: String = ""
    /// Mehrfachauswahl: Optionen umschalten, dann „Weiter/Absenden“
    var multi = false
}

enum PermissionScanner {
    struct Found {
        let prompt: PermissionPrompt
        let elements: [AXUIElement]
        /// Claude-Fenster, in dem die Anfrage steht (für „Zum Chat“)
        var window: AXUIElement? = nil
    }

    static func role(for label: String) -> PermissionPrompt.Option.Role? {
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count <= 40 else { return nil }
        let deny = ["nicht erlauben", "nicht zulassen", "ablehnen", "verweigern", "abweisen", "deny", "decline",
                    "don't allow", "dont allow", "do not allow", "reject", "disallow"]
        let always = ["immer erlauben", "immer zulassen", "always allow", "allow always", "für diesen chat", "for this chat",
                      "für diese unterhaltung", "for this conversation", "für diese sitzung", "for this session", "allow for", "dauerhaft"]
        let allow = ["einmal erlauben", "allow once", "erlauben", "zulassen", "allow", "genehmigen", "approve", "bestätigen"]
        if deny.contains(where: { l.contains($0) }) { return .deny }
        if always.contains(where: { l.contains($0) }) { return .always }
        if allow.contains(where: { l.contains($0) }) { return .allow }
        return nil
    }

    static func label(of el: AXUIElement) -> String {
        [AX.string(el, kAXTitleAttribute as String), AX.string(el, kAXDescriptionAttribute as String)]
            .compactMap { $0 }.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }

    /// Alle offenen Erlaubnis-Dialoge (z. B. mehrere Agenten gleichzeitig) – jeder nur einmal.
    static func buildAll(from candidates: [AXUIElement]) -> [Found] {
        var out: [Found] = []
        var consumed: [AXUIElement] = []
        for seed in candidates where role(for: label(of: seed)) != .deny {
            if consumed.contains(where: { CFEqual($0, seed) }) { continue }
            consumed.append(seed)
            guard let f = build(from: [seed]) else { continue }
            consumed.append(contentsOf: f.elements)
            let duplicate = out.contains { o in
                o.prompt.key == f.prompt.key && f.elements.allSatisfy { e in o.elements.contains { x in CFEqual(x, e) } }
            }
            if !duplicate {
                out.append(f)
            }
            if out.count >= 6 { break }
        }
        return out
    }

    /// Aus gefundenen Erlauben/Ablehnen-Knöpfen den gemeinsamen Dialog-Bereich bestimmen.
    static func build(from candidates: [AXUIElement]) -> Found? {
        guard let seed = candidates.first(where: { role(for: label(of: $0)) != .deny }) else { return nil }
        var container = seed
        for _ in 0..<7 {
            guard let p = AX.attr(container, kAXParentAttribute as String),
                  CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            container = p as! AXUIElement   // Typ oben geprüft
            var buttons: [(AXUIElement, String, PermissionPrompt.Option.Role)] = []
            var texts: [String] = []
            var stack = [container]
            var visited = 0
            while let el = stack.popLast(), visited < 500 {
                visited += 1
                let r = AX.string(el, kAXRoleAttribute as String) ?? ""
                if r == (kAXButtonRole as String) {
                    if let enabled = AX.attr(el, kAXEnabledAttribute as String) as? Bool, !enabled { continue }
                    let l = label(of: el)
                    if let role = role(for: l) { buttons.append((el, l, role)) }
                    continue
                }
                if r == (kAXStaticTextRole as String), let v = AX.string(el, kAXValueAttribute as String) {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 2 && !t.hasSuffix(":") && !texts.contains(t) { texts.append(t) }
                }
                stack.append(contentsOf: AX.children(el).reversed())
            }
            let hasAllow = buttons.contains { $0.2 == .allow || $0.2 == .always }
            let hasDeny = buttons.contains { $0.2 == .deny }
            if hasAllow && hasDeny {
                // gleiche Beschriftungen nur einmal
                var seen = Set<String>()
                let unique = buttons.filter { seen.insert($0.1.lowercased()).inserted }.prefix(4)
                let options = unique.enumerated().map { PermissionPrompt.Option(id: $0.offset, label: $0.element.1, role: $0.element.2) }
                let labels = Set(unique.map { $0.1 })
                let info = texts.filter { !labels.contains($0) }
                let title = info.first.map { String($0.prefix(90)) } ?? "Claude braucht deine Erlaubnis"
                let detail = info.dropFirst().prefix(3).joined(separator: " · ")
                let key = options.map(\.label).joined(separator: "|") + "|" + String(title.prefix(60))
                return Found(prompt: PermissionPrompt(key: key, title: title, detail: String(detail.prefix(180)), options: options),
                             elements: unique.map { $0.0 })
            }
        }
        return nil
    }
}

/// Rückfragen von Claude („Claude hat dir 3 Fragen gestellt“ – Karte über dem Eingabefeld).
/// Erkannt an der Karte mit der CSS-Klasse „--cds-question-row-h“ (sprachunabhängig).
enum QuestionScanner {
    static func isCard(_ el: AXUIElement) -> Bool {
        guard AX.string(el, kAXSubroleAttribute as String) == "AXApplicationGroup" else { return false }
        let dom = (AX.attr(el, "AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
        return dom.contains("cds-question-row-h")
    }

    private static let navWords = ["vorherige", "nächste", "minimieren", "previous", "next question", "minimize", "collapse", "einklappen"]
    private static let skipWords = ["überspringen", "skip"]

    static func parse(_ card: AXUIElement) -> PermissionScanner.Found? {
        var texts: [String] = []
        var optionEls: [(AXUIElement, String, Bool)] = []
        var skip: (AXUIElement, String)?
        var extras: [(AXUIElement, String)] = []
        var progress = ""
        var stack = [card]
        var visited = 0
        while let el = stack.popLast(), visited < 400 {
            visited += 1
            let role = AX.string(el, kAXRoleAttribute as String) ?? ""
            if role == (kAXCheckBoxRole as String) || role == (kAXRadioButtonRole as String) {
                let l = PermissionScanner.label(of: el).trimmingCharacters(in: .whitespacesAndNewlines)
                if !l.isEmpty {
                    let on = (AX.attr(el, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                    optionEls.append((el, l, on))
                }
                continue
            }
            if role == (kAXButtonRole as String) {
                let l = PermissionScanner.label(of: el).trimmingCharacters(in: .whitespacesAndNewlines)
                let low = l.lowercased()
                if low.isEmpty || navWords.contains(where: { low.contains($0) }) { continue }
                if skipWords.contains(where: { low.contains($0) }) { skip = (el, l) } else { extras.append((el, l)) }
                continue
            }
            if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) { continue }
            if role == (kAXStaticTextRole as String),
               let v = AX.string(el, kAXValueAttribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                if v.range(of: #"^\d+\s+(von|of)\s+\d+$"#, options: .regularExpression) != nil { progress = v }
                else if !texts.contains(v) { texts.append(v) }
            }
            stack.append(contentsOf: AX.children(el).reversed())
        }
        guard !optionEls.isEmpty else { return nil }
        var question = texts.first ?? ""
        if question.isEmpty, let d = AX.string(card, kAXDescriptionAttribute as String) {
            question = d.components(separatedBy: ". ").first ?? d
        }
        var options: [PermissionPrompt.Option] = []
        var elements: [AXUIElement] = []
        for (i, o) in optionEls.prefix(6).enumerated() {
            let (label, detail) = split(o.1)
            options.append(.init(id: i, label: label, role: .other, detail: detail, checked: o.2))
            elements.append(o.0)
        }
        let multi = !extras.isEmpty
        for e in extras.prefix(1) {
            options.append(.init(id: options.count, label: e.1, role: .allow))
            elements.append(e.0)
        }
        if let s = skip {
            options.append(.init(id: options.count, label: s.1, role: .deny))
            elements.append(s.0)
        }
        let key = "q|" + question + "|" + optionEls.map(\.1).joined(separator: "|")
        let prompt = PermissionPrompt(kind: .question, key: key, title: String(question.prefix(140)),
                                      detail: multi ? "Mehrere Antworten möglich" : "",
                                      options: options, progress: progress, multi: multi)
        return PermissionScanner.Found(prompt: prompt, elements: elements)
    }

    /// Beschriftung + Beschreibung stehen in Claude in einem Text („Gründlich Alles testen …“).
    /// Trennen, wo es eindeutig geht: nach „(Recommended)“/„(Empfohlen)“ oder einem Doppelpunkt/Gedankenstrich.
    static func split(_ s: String) -> (String, String) {
        for marker in ["(Recommended)", "(Empfohlen)", " – ", " - ", ": "] {
            if let r = s.range(of: marker) {
                let head = s[..<(marker.hasPrefix("(") ? r.upperBound : r.lowerBound)].trimmingCharacters(in: .whitespaces)
                let tail = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty && head.count <= 60 { return (head, tail) }
            }
        }
        return (s, "")
    }
}

extension ClaudeService {
    /// Antwort aus der Notch → passenden Knopf in Claude drücken.
    func respond(_ option: PermissionPrompt.Option) {
        guard let p = permission else { return }
        // Mehrfachauswahl: nur umschalten, Karte bleibt offen
        if p.kind == .question, p.multi, option.role == .other {
            if option.id < permissionElements.count {
                _ = AXUIElementPerformAction(permissionElements[option.id], kAXPressAction as CFString)
                var np = p
                if let i = np.options.firstIndex(where: { $0.id == option.id }) {
                    var o = np.options[i]; o.checked.toggle()
                    var opts = np.options; opts[i] = o
                    np = PermissionPrompt(kind: np.kind, key: np.key, title: np.title, detail: np.detail, options: opts, progress: np.progress, multi: true)
                }
                permission = np
                haptic()
            }
            return
        }
        if p.key.hasPrefix("ext|") {
            replyExternal(p, option)
            permission = nil
            haptic()
            if option.role != .other {
                IslandModel.shared.show(Toast(symbol: option.role == .deny ? "hand.raised.slash.fill" : "checkmark.shield.fill",
                                              tint: option.role == .deny ? .red : .green, title: option.label,
                                              subtitle: "an Claude Code gesendet", duration: 1.6))
            }
            applyPrompts(lastAXPrompts)
            return
        }
        answeredKey = p.key
        answeredAt = Date()
        answeredLabel = option.label
        retried = false
        permission = nil
        DevBridge.log("Antwort: \(option.label)")
        let ok: Bool
        if option.id < permissionElements.count {
            ok = AXUIElementPerformAction(permissionElements[option.id], kAXPressAction as CFString) == .success
        } else {
            ok = false
        }
        permissionElements = []
        haptic()
        if ok && p.kind == .question {
            // Nächste Frage wird gleich automatisch erkannt – nur kurze Bestätigung
            if option.role != .deny {
                IslandModel.shared.show(Toast(symbol: "checkmark.bubble.fill", tint: .green, title: option.label,
                                              subtitle: "an Claude gesendet", trailing: .check, duration: 1.4))
            }
        } else if ok {
            IslandModel.shared.show(Toast(
                symbol: option.role == .deny ? "hand.raised.slash.fill" : "checkmark.shield.fill",
                tint: option.role == .deny ? .red : .green,
                title: option.label, subtitle: "an Claude gesendet", trailing: option.role == .deny ? .none : .check, duration: 1.8))
        } else if option.id >= 0 && !permissionIsDemo {
            AppInfo.activate(Const.claudeBundle)
            IslandModel.shared.show(Toast(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                          title: "Bitte direkt in Claude bestätigen", duration: 3))
        }
        permissionIsDemo = false
        IslandModel.shared.setNeedsRecompute()
    }

    func openClaudeForPermission() {
        if let p = permission, p.key.hasPrefix("ext|"), let o = p.options.first(where: { $0.role == .other }) {
            respond(o)   // Claude Code: Frage zurück ans Terminal
            return
        }
        permission = nil
        focusChat()
    }

    /// Alle offenen Anfragen (Erlaubnisse + Rückfragen aus allen Claude-Fenstern/Agenten + Claude-Code-Hooks).
    /// Gezeigt wird immer eine; nach der Antwort kommt automatisch die nächste.
    func applyPrompts(_ found: [PermissionScanner.Found]) {
        guard !permissionIsDemo else { return }
        var list = found
        // gerade beantwortet → kurz ignorieren, bis Claude den Dialog geschlossen hat.
        // Ist er nach 1,5 s immer noch da, kam der Klick nicht an → einmal erneut drücken.
        if let i = list.firstIndex(where: { $0.prompt.key == answeredKey }), Date().timeIntervalSince(answeredAt) < 8 {
            let f = list[i]
            if !retried, Date().timeIntervalSince(answeredAt) > 1.5,
               let j = f.prompt.options.firstIndex(where: { $0.label == answeredLabel }), j < f.elements.count {
                retried = true
                DevBridge.log("Wiederhole Klick: \(answeredLabel)")
                _ = AXUIElementPerformAction(f.elements[j], kAXPressAction as CFString)
            }
            list.remove(at: i)
        }
        let ext = externalPrompts.map { PermissionScanner.Found(prompt: $0, elements: []) }
        let all = list + ext
        if queueCount != all.count { queueCount = all.count }
        guard !all.isEmpty else {
            if permission != nil { permission = nil }
            permissionElements = []
            return
        }
        // Die gerade gezeigte Anfrage bleibt stehen, solange es sie noch gibt
        let pick = all.first(where: { $0.prompt.key == permission?.key }) ?? all[0]
        permissionElements = pick.elements
        if let w = pick.window { attentionWindow = w }
        if permission?.key != pick.prompt.key {
            permission = pick.prompt
            DevBridge.log("\(pick.prompt.kind == .question ? "Rückfrage" : "Erlaubnis") erkannt (\(all.count) offen): \(pick.prompt.title) · Optionen: \(pick.prompt.options.map(\.label))")
            NSSound(named: "Funk")?.play()
            haptic()
        } else if pick.prompt.multi == false, permission != pick.prompt, pick.prompt.kind == .question {
            permission = pick.prompt
        }
    }

    // MARK: Claude Code (Hook „PermissionRequest“)

    /// Anfrage von notch-mcp --hook permission: wartet, bis in der Insel geantwortet wird.
    func addExternalPrompt(id: String, title: String, detail: String) {
        guard !externalPrompts.contains(where: { $0.key == "ext|" + id }) else { return }
        let p = PermissionPrompt(key: "ext|" + id, title: title, detail: detail,
                                 options: [.init(id: 0, label: "Ablehnen", role: .deny),
                                           .init(id: 1, label: "Erlauben", role: .allow),
                                           .init(id: 2, label: "Im Terminal", role: .other)])
        externalPrompts.append(p)
        // Nach 10 Minuten verfällt die Anfrage (der Hook gibt dann an das Terminal zurück).
        // Wird im Terminal geantwortet, endet der Hook – dann verschwindet die Anfrage auch hier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.dropExternal(id) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, self.externalPrompts.contains(where: { $0.key == "ext|" + id }) else { t.invalidate(); return }
            if !HookChannel.isAlive(id) { t.invalidate(); self.dropExternal(id) }
        }
        applyPrompts(lastAXPrompts)
    }

    func dropExternal(_ id: String) {
        externalPrompts.removeAll { $0.key == "ext|" + id }
        applyPrompts(lastAXPrompts)
    }

    func replyExternal(_ p: PermissionPrompt, _ option: PermissionPrompt.Option) {
        let id = String(p.key.dropFirst(4))
        let decision = option.role == .allow ? "allow" : (option.role == .deny ? "deny" : "ask")
        // Antwort als Datei in einem privaten Ordner (nur dieser Benutzer) – nicht als systemweite Nachricht,
        // damit keine andere App eine Erlaubnis „mitlesen“ oder fälschen kann.
        if UUID(uuidString: id) != nil {
            let f = HookChannel.dir.appendingPathComponent("ans-\(id)")
            FileManager.default.createFile(atPath: f.path, contents: Data(decision.utf8), attributes: [.posixPermissions: 0o600])
        }
        externalPrompts.removeAll { $0.key == p.key }
        DevBridge.log("Claude-Code-Antwort: \(decision)")
    }

    func demoQuestion() {
        permissionIsDemo = true
        permissionElements = []
        permission = PermissionPrompt(kind: .question, key: "demoq", title: "Welchen Weg möchtest du gehen?",
                                      detail: "Claude möchte wissen, wie es weitermachen soll",
                                      options: [.init(id: 0, label: "Schnell & einfach", role: .other, detail: "Nur das Nötigste, in 5 Minuten fertig"),
                                                .init(id: 1, label: "Gründlich", role: .other, detail: "Alles testen und dokumentieren"),
                                                .init(id: 2, label: "Erst einen Plan zeigen", role: .other, detail: ""),
                                                .init(id: 3, label: "Überspringen", role: .deny)], progress: "1 von 2")
        IslandModel.shared.setNeedsRecompute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.permissionIsDemo else { return }
            self.permissionIsDemo = false
            self.permission = nil
        }
    }

    func demoPermission() {
        permissionIsDemo = true
        permissionElements = []
        permission = PermissionPrompt(key: "demo", title: "Claude möchte „notch_status“ von notch-island verwenden",
                                      detail: "Zeigt den Fortschritt einer Aufgabe in der Notch",
                                      options: [.init(id: 0, label: "Ablehnen", role: .deny),
                                                .init(id: 1, label: "Einmal erlauben", role: .allow),
                                                .init(id: 2, label: "Immer erlauben", role: .always)])
        IslandModel.shared.setNeedsRecompute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.permissionIsDemo else { return }
            self.permissionIsDemo = false
            self.permission = nil
        }
    }
}

/// Privater Austauschordner mit dem Claude-Code-Hook (notch-mcp --hook permission)
enum HookChannel {
    static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchIsland/hook")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }()

    /// Anfrage lesen, die der Hook abgelegt hat
    /// Lebt der wartende Hook-Prozess noch? (Antwortet man im Terminal, beendet Claude Code ihn.)
    static func isAlive(_ id: String) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("req-\(id).json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let pid = (d["pid"] as? NSNumber)?.int32Value, pid > 0 else { return true }
        return kill(pid, 0) == 0
    }

    /// Alte Reste (abgestürzte Hooks) aufräumen
    static func cleanup() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(m) > 900 { try? fm.removeItem(at: f) }
        }
    }

    static func request(_ id: String) -> (title: String, detail: String)? {
        guard UUID(uuidString: id) != nil,
              let data = try? Data(contentsOf: dir.appendingPathComponent("req-\(id).json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (String((d["title"] as? String ?? "Claude Code möchte etwas ausführen").prefix(140)),
                String((d["detail"] as? String ?? "").prefix(200)))
    }
}

// MARK: - Ansicht in der Notch

struct PermissionView: View {
    @ObservedObject var claude = ClaudeService.shared
    @ObservedObject var model = IslandModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height - 2)
            if let p = claude.permission {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 11) {
                        ZStack {
                            Circle().fill(Color.claude.opacity(0.2))
                            Image(systemName: p.kind == .question ? "questionmark.bubble.fill" : "lock.shield.fill")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.claude)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.kind == .question ? "Claude fragt" : "Claude braucht deine Erlaubnis")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.claude)
                                if claude.queueCount > 1 {
                                    Text("\(claude.queueCount) offen").font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.claude))
                                }
                                if !p.progress.isEmpty {
                                    Text(p.progress).font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(Color.dim)
                                }
                            }
                            Text(p.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                            if !p.detail.isEmpty {
                                Text(p.detail).font(.system(size: 11.5)).foregroundStyle(Color.dim).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Button { claude.openClaudeForPermission() } label: {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dim).frame(width: 24, height: 24)
                        }
                        .buttonStyle(PressableStyle())
                        .help(p.kind == .question ? "In Claude antworten (eigene Antwort)" : "In Claude ansehen")
                    }
                    if p.kind == .question {
                        VStack(spacing: 5) {
                            ForEach(p.options.filter { $0.role == .other }) { o in
                                Button { claude.respond(o) } label: {
                                    HStack(spacing: 9) {
                                        if p.multi {
                                            Image(systemName: o.checked ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(o.checked ? Color.claude : Color.dim)
                                                .frame(width: 18, height: 18)
                                        } else {
                                            Text("\(o.id + 1)")
                                                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                                .foregroundStyle(Color.claude)
                                                .frame(width: 18, height: 18)
                                                .background(Circle().fill(Color.claude.opacity(0.18)))
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(o.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(o.detail.isEmpty ? 2 : 1)
                                            if !o.detail.isEmpty {
                                                Text(o.detail).font(.system(size: 10.5)).foregroundStyle(Color.dim).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if !p.multi {
                                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.dim)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle())
                            }
                            let actions = p.options.filter { $0.role != .other }
                            if !actions.isEmpty {
                                HStack(spacing: 8) {
                                    Text("Eigene Antwort: Pfeil oben rechts").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.35))
                                    Spacer(minLength: 0)
                                    ForEach(actions) { o in
                                        Button { claude.respond(o) } label: {
                                            Text(o.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                                .foregroundStyle(o.role == .allow ? Color.black : Color.white.opacity(0.75))
                                                .padding(.horizontal, 12).padding(.vertical, 6)
                                                .background(Capsule().fill(o.role == .allow ? Color.claude : Color.white.opacity(0.12)))
                                                .contentShape(Capsule())
                                        }
                                        .buttonStyle(PressableStyle())
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            ForEach(p.options) { o in
                                Button { claude.respond(o) } label: {
                                    Text(o.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                        .foregroundStyle(fg(o.role))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(Capsule().fill(bg(o.role)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    private func bg(_ r: PermissionPrompt.Option.Role) -> Color {
        switch r {
        case .deny: return Color.white.opacity(0.12)
        case .allow: return Color.white
        case .always: return Color.claude
        case .other: return Color.white.opacity(0.12)
        }
    }

    private func fg(_ r: PermissionPrompt.Option.Role) -> Color {
        switch r {
        case .deny: return Color(red: 1, green: 0.45, blue: 0.42)
        case .allow: return .black
        case .always: return .black
        case .other: return .white
        }
    }
}
