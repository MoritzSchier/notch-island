import AppKit
import SwiftUI

/// Eine offene Anfrage aus einem Claude-Code-Hook (notch-mcp --hook permission|question).
struct CodeRequest {
    enum Kind { case permission, question }

    struct Question {
        let text: String
        let header: String
        let options: [(label: String, detail: String)]
        let multi: Bool
    }

    let id: String
    let kind: Kind
    let sessionId: String
    let source: String
    // Erlaubnis
    var tool = ""
    var detail = ""
    var description = ""
    var ruleText = ""
    var canAlways = false
    // Rückfrage
    var questions: [Question] = []
    var index = 0
    var answers: [String: String] = [:]
    var selected: Set<Int> = []
}

extension ClaudeService {
    // MARK: Eingang

    /// Neue Anfrage vom Hook: bestätigen (sonst gibt der Hook nach 3 s ans Terminal zurück) und einreihen.
    func addCodeRequest(id: String, kind: CodeRequest.Kind) {
        guard UUID(uuidString: id) != nil, codeRequests[id] == nil,
              let data = try? Data(contentsOf: HookChannel.dir.appendingPathComponent("req-\(id).json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let sessionId = d["sessionId"] as? String ?? ""
        let source = Self.sessionLabel(sessionId: sessionId, cwd: d["cwd"] as? String ?? "")
        var req = CodeRequest(id: id, kind: kind, sessionId: sessionId, source: source)

        switch kind {
        case .permission:
            req.tool = d["tool"] as? String ?? "Tool"
            req.detail = d["detail"] as? String ?? ""
            req.description = d["description"] as? String ?? ""
            let suggestions = d["suggestions"] as? [[String: Any]] ?? []
            req.canAlways = !suggestions.isEmpty
            req.ruleText = Self.describe(suggestions)
        case .question:
            let raw = d["questions"] as? [[String: Any]] ?? []
            req.questions = raw.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, String)? in
                    guard let l = o["label"] as? String else { return nil }
                    return (l, o["description"] as? String ?? "")
                }
                return CodeRequest.Question(text: text, header: q["header"] as? String ?? "",
                                            options: opts, multi: q["multiSelect"] as? Bool ?? false)
            }
            guard !req.questions.isEmpty else { return }
        }

        FileManager.default.createFile(atPath: HookChannel.dir.appendingPathComponent("seen-\(id)").path,
                                       contents: Data("1".utf8), attributes: [.posixPermissions: 0o600])
        codeRequests[id] = req
        externalPrompts.append(prompt(for: req))
        // Antwortet man im Terminal oder bricht die Session ab, endet der Hook → Anfrage verschwindet auch hier.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, self.codeRequests[id] != nil else { t.invalidate(); return }
            if !HookChannel.isAlive(id) { t.invalidate(); self.dropExternal(id) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.dropExternal(id) }
        applyPrompts(lastAXPrompts)
    }

    // MARK: Darstellung

    func prompt(for r: CodeRequest) -> PermissionPrompt {
        switch r.kind {
        case .permission:
            var options: [PermissionPrompt.Option] = [.init(id: 0, label: tr("Ablehnen"), role: .deny),
                                                      .init(id: 1, label: tr("Erlauben"), role: .allow)]
            if r.canAlways { options.append(.init(id: 2, label: tr("Immer erlauben"), role: .always)) }
            options.append(.init(id: 3, label: tr("Im Terminal"), role: .other))
            let what = r.detail.isEmpty ? r.tool : "\(r.tool): \(r.detail)"
            var info = r.description
            if r.canAlways, !r.ruleText.isEmpty {
                info = (info.isEmpty ? "" : info + " · ") + tr("Immer gilt für ") + r.ruleText
            }
            return PermissionPrompt(key: "ext|" + r.id, title: String(what.prefix(160)), detail: String(info.prefix(200)),
                                    options: options, sessionId: r.sessionId, source: r.source)
        case .question:
            let q = r.questions[min(r.index, r.questions.count - 1)]
            var options = q.options.enumerated().map { i, o in
                PermissionPrompt.Option(id: i, label: o.label, role: .other, detail: o.detail, checked: r.selected.contains(i))
            }
            if q.multi {
                let last = r.index == r.questions.count - 1
                options.append(.init(id: 100, label: last ? tr("Absenden") : tr("Weiter"), role: .allow))
            }
            options.append(.init(id: 101, label: tr("Im Terminal"), role: .deny))
            let progress = r.questions.count > 1 ? tr("\(r.index + 1) von \(r.questions.count)") : ""
            let detail = [q.header, q.multi ? tr("Mehrere Antworten möglich") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return PermissionPrompt(kind: .question, key: "ext|" + r.id, title: String(q.text.prefix(220)), detail: detail,
                                    options: options, progress: progress, multi: q.multi,
                                    sessionId: r.sessionId, source: r.source, allowsText: true)
        }
    }

    // MARK: Antworten

    func respondCode(_ p: PermissionPrompt, _ option: PermissionPrompt.Option) {
        let id = String(p.key.dropFirst(4))
        guard var r = codeRequests[id] else { dropExternal(id); return }
        switch r.kind {
        case .permission:
            let decision: String
            switch option.role {
            case .allow: decision = "allow"
            case .always: decision = "always"
            case .deny: decision = "deny"
            case .other: decision = "terminal"
            }
            finishCode(id, answer: Data(decision.utf8))
            if decision == "terminal" {
                focusTerminal(sessionId: r.sessionId)
            } else {
                IslandModel.shared.show(Toast(symbol: decision == "deny" ? "hand.raised.slash.fill" : "checkmark.shield.fill",
                                              tint: decision == "deny" ? .red : .green, title: option.label,
                                              subtitle: tr("an \(r.source) gesendet"), duration: 1.4))
            }
        case .question:
            let q = r.questions[r.index]
            switch option.role {
            case .other where q.multi:
                if r.selected.contains(option.id) { r.selected.remove(option.id) } else { r.selected.insert(option.id) }
                updateCode(r)
            case .other:
                r.answers[q.text] = option.label
                advanceCode(r)
            case .allow:
                let labels = q.options.enumerated().filter { r.selected.contains($0.offset) }.map(\.element.label)
                guard !labels.isEmpty else { return }
                r.answers[q.text] = labels.joined(separator: ", ")
                advanceCode(r)
            case .deny, .always:
                finishCode(id, answer: Data("{}".utf8))
                focusTerminal(sessionId: r.sessionId)
            }
        }
        haptic()
    }

    /// Eigene Antwort aus dem Textfeld
    func respondText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let p = permission, p.key.hasPrefix("ext|"),
              var r = codeRequests[String(p.key.dropFirst(4))], r.kind == .question else { return }
        r.answers[r.questions[r.index].text] = t
        advanceCode(r)
        haptic()
    }

    private func advanceCode(_ r: CodeRequest) {
        var r = r
        r.index += 1
        r.selected = []
        if r.index >= r.questions.count {
            let data = (try? JSONSerialization.data(withJSONObject: ["answers": r.answers])) ?? Data("{}".utf8)
            finishCode(r.id, answer: data)
            IslandModel.shared.show(Toast(symbol: "checkmark.bubble.fill", tint: .green, title: tr("Antwort gesendet"),
                                          subtitle: r.source, trailing: .check, duration: 1.4))
        } else {
            updateCode(r)
        }
    }

    private func updateCode(_ r: CodeRequest) {
        codeRequests[r.id] = r
        let np = prompt(for: r)
        if let i = externalPrompts.firstIndex(where: { $0.key == np.key }) { externalPrompts[i] = np }
        permission = np
    }

    private func finishCode(_ id: String, answer: Data) {
        let f = HookChannel.dir.appendingPathComponent("ans-\(id)")
        FileManager.default.createFile(atPath: f.path, contents: answer, attributes: [.posixPermissions: 0o600])
        codeRequests[id] = nil
        externalPrompts.removeAll { $0.key == "ext|" + id }
        lastPromptAt = Date()
        answeredAt = Date()
        permission = nil
        applyPrompts(lastAXPrompts)
        IslandModel.shared.setNeedsRecompute()
    }

    /// Klick auf eine rote Session: deren Anfrage nach vorn holen.
    @discardableResult
    func showPending(for sessionId: String) -> Bool {
        guard let p = externalPrompts.first(where: { $0.sessionId == sessionId }) else { return false }
        permissionElements = []
        permission = p
        IslandModel.shared.setNeedsRecompute()
        return true
    }

    func focusTerminal(sessionId: String) {
        if let pid = SessionRegistry.load()[sessionId]?.pid { TerminalFocus.activateApp(owning: pid) }
    }

    // MARK: Hilfen

    static func sessionLabel(sessionId: String, cwd: String) -> String {
        if let s = SessionStore.shared.sessions.first(where: { $0.sessionId == sessionId }) { return s.displayName }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }

    /// „Bash(npm test:*)“ bzw. „Modus acceptEdits“ – was „Immer erlauben“ tatsächlich speichert.
    static func describe(_ suggestions: [[String: Any]]) -> String {
        var parts: [String] = []
        for s in suggestions {
            switch s["type"] as? String {
            case "addRules":
                for rule in s["rules"] as? [[String: Any]] ?? [] {
                    let tool = rule["toolName"] as? String ?? "?"
                    if let c = rule["ruleContent"] as? String, !c.isEmpty { parts.append("\(tool)(\(c))") } else { parts.append(tool) }
                }
            case "setMode": parts.append(tr("Modus ") + (s["mode"] as? String ?? "?"))
            case "addDirectories": parts.append(tr("Ordner ") + ((s["directories"] as? [String])?.joined(separator: ", ") ?? ""))
            default: break
            }
        }
        return parts.joined(separator: ", ")
    }
}
