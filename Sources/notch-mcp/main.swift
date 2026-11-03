import Foundation

// notch-mcp – kleine Brücke zwischen Claude und der Notch-Island-App.
//   • ohne Argumente: MCP-Server (stdio) für Claude Desktop
//   • --install-claude: trägt sich in die Claude-Desktop-Konfiguration ein
//   • --hook <running|waiting|done>: für Claude-Code-Hooks
//   • --send '<json>': schickt eine beliebige Meldung an die App

let noteName = Notification.Name("notchisland.activity")

func post(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let s = String(data: data, encoding: .utf8) else { return }
    DistributedNotificationCenter.default().postNotificationName(noteName, object: s, userInfo: nil, deliverImmediately: true)
}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let args = CommandLine.arguments

// MARK: Installation

if args.contains("--install-claude") {
    let exe = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let cfgURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    try? FileManager.default.createDirectory(at: cfgURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var cfg: [String: Any] = [:]
    if let raw = try? Data(contentsOf: cfgURL), !raw.isEmpty {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            print("FEHLER: \(cfgURL.path) ist kein gültiges JSON.")
            exit(1)
        }
        cfg = obj
        try? raw.write(to: cfgURL.appendingPathExtension("backup"))
    }
    var servers = cfg["mcpServers"] as? [String: Any] ?? [:]
    servers["notch-island"] = ["command": exe, "args": [String]()]
    cfg["mcpServers"] = servers
    do {
        let out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: cfgURL, options: .atomic)
        print("✓ Claude-Verbindung eingetragen: \(cfgURL.path)")
        exit(0)
    } catch {
        print("FEHLER beim Schreiben: \(error)")
        exit(1)
    }
}

// MARK: Claude Code einrichten (Hooks in ~/.claude/settings.json eintragen)

if args.contains("--install-claude-code") {
    let exe = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let cmd = exe.replacingOccurrences(of: " ", with: "\\ ")
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var cfg: [String: Any] = [:]
    if let raw = try? Data(contentsOf: url), !raw.isEmpty {
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            print("FEHLER: \(url.path) ist kein gültiges JSON – bitte von Hand prüfen.")
            exit(1)
        }
        cfg = obj
        try? raw.write(to: url.appendingPathExtension("backup"))
    }
    var hooks = cfg["hooks"] as? [String: Any] ?? [:]
    // (Ereignis, Argument, Timeout, Matcher)
    var wanted: [(String, String, Int?, String?)] = [("PermissionRequest", "permission", 600, nil),
                                                     ("PreToolUse", "question", 600, "AskUserQuestion")]
    // Ampel pro Session – außer es läuft schon ein eigener Status-Hook (notch-hook.py), sonst zählt alles doppelt
    let ownStatusHook = (hooks.values.compactMap { $0 as? [[String: Any]] }.joined()).contains { group in
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("notch-hook.py") }
    }
    if !ownStatusHook {
        for event in ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd", "SubagentStop"] {
            wanted.append((event, "session \(event)", 5, nil))
        }
        wanted.append(("PreToolUse", "session SubagentStart", 5, "Agent|Task"))
    }
    // Alte Notch-Island-Einträge überall entfernen (auch frühere Status-Hooks)
    for event in ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd", "SubagentStop",
                  "PermissionRequest", "PreToolUse"] {
        var list = hooks[event] as? [[String: Any]] ?? []
        list = list.filter { group in
            let hs = group["hooks"] as? [[String: Any]] ?? []
            return !hs.contains { ($0["command"] as? String ?? "").contains("notch-mcp") }
        }
        if list.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = list }
    }
    for (event, arg, timeout, matcher) in wanted {
        var list = hooks[event] as? [[String: Any]] ?? []
        var h: [String: Any] = ["type": "command", "command": "\(cmd) --hook \(arg)"]
        if let timeout { h["timeout"] = timeout }
        var group: [String: Any] = ["hooks": [h]]
        if let matcher { group["matcher"] = matcher }
        list.append(group)
        hooks[event] = list
    }
    cfg["hooks"] = hooks
    do {
        let out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
        print("✓ Claude Code verbunden: \(url.path)")
        exit(0)
    } catch {
        print("FEHLER beim Schreiben: \(error)")
        exit(1)
    }
}

// MARK: Claude-Code-Hooks
//
// Beide Hooks halten die Anfrage im Terminal zurück, bis in der Notch geantwortet wird.
// Läuft die App nicht, bestätigt sie die Anfrage nicht binnen 3 s, antwortet niemand oder kommt
// „Im Terminal“, endet der Hook ohne Ausgabe → Claude Code fragt wie gewohnt im Terminal.

let hookDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchIsland/hook")

func readHookInput() -> [String: Any] {
    guard isatty(fileno(stdin)) == 0 else { return [:] }
    return (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]) ?? [:]
}

/// Anfrage ablegen, App benachrichtigen, auf Antwortdatei warten. nil = an das Terminal zurückgeben.
func waitForNotch(kind: String, request: [String: Any]) -> Data? {
    let id = UUID().uuidString
    // Privater Austauschordner (nur dieser Benutzer); Inhalt der Anfrage nie systemweit verschicken
    try? FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let reqURL = hookDir.appendingPathComponent("req-\(id).json")
    let ansURL = hookDir.appendingPathComponent("ans-\(id)")
    let seenURL = hookDir.appendingPathComponent("seen-\(id)")
    var req = request
    req["pid"] = Int(getpid())
    guard let data = try? JSONSerialization.data(withJSONObject: req) else { return nil }
    FileManager.default.createFile(atPath: reqURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    defer {
        for u in [reqURL, ansURL, seenURL] { try? FileManager.default.removeItem(at: u) }
    }
    post(["kind": kind, "id": id])
    var answer: Data?
    let start = Date()
    let deadline = start.addingTimeInterval(590)
    while answer == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        if let d = try? Data(contentsOf: ansURL), !d.isEmpty { answer = d; break }
        // App läuft nicht oder hat die Anfrage nicht angenommen → sofort ans Terminal
        if Date().timeIntervalSince(start) > 3 && !FileManager.default.fileExists(atPath: seenURL.path) { break }
    }
    if answer == nil {
        post(["kind": "permission_cancel", "id": id])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    return answer
}

func emit(_ out: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data) }
}

// PermissionRequest: Erlauben / Immer erlauben / Ablehnen
if args.contains("--hook"), args.contains("permission") {
    let input = readHookInput()
    let tool = input["tool_name"] as? String ?? "Tool"
    // Rückfragen und Plan-Freigaben haben eigene Dialoge im Terminal
    if tool == "AskUserQuestion" || tool == "ExitPlanMode" { exit(0) }
    let ti = input["tool_input"] as? [String: Any] ?? [:]
    let what = (ti["command"] as? String) ?? (ti["file_path"] as? String) ?? (ti["url"] as? String)
        ?? (ti["pattern"] as? String) ?? (ti["description"] as? String) ?? ""
    let suggestions = (input["permission_suggestions"] as? [[String: Any]] ?? []).filter {
        ($0["type"] as? String) != "setMode" || ($0["mode"] as? String) != "bypassPermissions"
    }
    let req: [String: Any] = ["tool": tool, "detail": String(what.prefix(400)),
                              "description": ti["description"] as? String ?? "",
                              "sessionId": input["session_id"] as? String ?? "",
                              "cwd": input["cwd"] as? String ?? "",
                              "suggestions": suggestions]
    guard let raw = waitForNotch(kind: "permission", request: req),
          let decision = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          ["allow", "always", "deny"].contains(decision) else { exit(0) }
    var dec: [String: Any] = ["behavior": decision == "deny" ? "deny" : "allow"]
    if decision == "deny" { dec["message"] = "In der Notch abgelehnt" }
    if decision == "always", !suggestions.isEmpty { dec["updatedPermissions"] = suggestions }
    emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": dec]])
    exit(0)
}

// PreToolUse für AskUserQuestion: Fragen in der Notch beantworten
if args.contains("--hook"), args.contains("question") {
    let input = readHookInput()
    guard (input["tool_name"] as? String) == "AskUserQuestion",
          let ti = input["tool_input"] as? [String: Any],
          let questions = ti["questions"] as? [[String: Any]], !questions.isEmpty else { exit(0) }
    let req: [String: Any] = ["questions": questions,
                              "sessionId": input["session_id"] as? String ?? "",
                              "cwd": input["cwd"] as? String ?? ""]
    guard let raw = waitForNotch(kind: "question", request: req),
          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let answers = obj["answers"] as? [String: String], !answers.isEmpty else { exit(0) }
    var updated = ti
    updated["answers"] = answers
    emit(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]])
    exit(0)
}

// Ampel pro Session: schreibt ~/.claude/notch/sessions/<id>.json, die App liest den Ordner.
// Ereignisse: SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd,
//             SubagentStart (PreToolUse für Agent/Task), SubagentStop
if let i = args.firstIndex(of: "--hook"), args.count > i + 1, args[i + 1] == "session" {
    let input = readHookInput()
    let event = args.count > i + 2 ? args[i + 2] : (input["hook_event_name"] as? String ?? "")
    let sessionId = input["session_id"] as? String ?? "unknown"
    guard sessionId.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { exit(0) }
    let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    // NOTCH_SESSIONS_DIR nur für Tests (die App räumt Dateien ohne lebende Session sofort weg)
    let dir = ProcessInfo.processInfo.environment["NOTCH_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/sessions")
    let file = dir.appendingPathComponent(sessionId + ".json")
    if event == "SessionEnd" { try? FileManager.default.removeItem(at: file); exit(0) }

    let previous = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    var subagents = (previous["subagents"] as? NSNumber)?.intValue ?? 0
    var mainStopped = previous["mainStopped"] as? Bool ?? false
    let message = String((input["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    let status: String
    switch event {
    case "SessionStart":
        status = "ready"; subagents = 0; mainStopped = false
    case "UserPromptSubmit":
        // Ein neuer Turn startet sauber – heilt auch einen verrutschten Zähler
        status = "working"; subagents = 0; mainStopped = false
    case "Notification":
        // Nach 60 s Leerlauf schickt Claude auch einen Hinweis – das ist keine Frage, fertig bleibt grün
        let idleNudge = message.lowercased().contains("waiting for your input")
        status = (idleNudge && mainStopped && subagents == 0) ? (previous["status"] as? String ?? "done") : "blocked"
    case "SubagentStart":
        subagents += 1; status = "working"
    case "SubagentStop":
        subagents = max(0, subagents - 1)
        // Ein fertiger Subagent darf eine offene Frage nicht verdecken
        status = (previous["status"] as? String) == "blocked" ? "blocked" : ((mainStopped && subagents == 0) ? "done" : "working")
    case "Stop":
        mainStopped = true; status = subagents == 0 ? "done" : "working"
    default:
        exit(0)
    }
    let stamp: String = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: Date())
    }()
    var record: [String: Any] = [
        "sessionId": sessionId, "status": status,
        "project": (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent,
        "cwd": cwd, "startedAt": previous["startedAt"] as? String ?? stamp, "updatedAt": stamp,
        "subagents": subagents, "mainStopped": mainStopped,
    ]
    // Nur eine blockierte Session zeigt eine Meldung, und die überlebt Folge-Ereignisse
    if status == "blocked" {
        let m = message.isEmpty ? (previous["message"] as? String ?? "") : message
        if !m.isEmpty { record["message"] = m }
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: record) {
        let tmp = file.appendingPathExtension("tmp")
        if FileManager.default.createFile(atPath: tmp.path, contents: data) {
            _ = rename(tmp.path, file.path)   // atomar ersetzen
        }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--hook") {
    let state = args.count > i + 1 ? args[i + 1] : "running"
    var input: [String: Any] = [:]
    if isatty(fileno(stdin)) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        input = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    var msg: [String: Any] = ["kind": "claude", "source": "code", "state": state]
    let project = (input["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
    if let p = input["prompt"] as? String {
        msg["title"] = "Claude Code" + (project.map { " · \($0)" } ?? "")
        msg["detail"] = String(p.prefix(80))
    } else if let m = input["message"] as? String {
        msg["detail"] = m
    }
    if state == "done" { msg["title"] = "Claude Code ist fertig" + (project.map { " · \($0)" } ?? "") }
    post(msg)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    exit(0)
}

if let i = args.firstIndex(of: "--send"), args.count > i + 1,
   let d = try? JSONSerialization.jsonObject(with: Data(args[i + 1].utf8)) as? [String: Any] {
    post(d)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    exit(0)
}

// MARK: MCP-Server (JSON-RPC über stdio)

let tools: [[String: Any]] = [
    [
        "name": "notch_status",
        "description": "Zeigt den Fortschritt einer Aufgabe live in der Notch (Dynamic Island) auf dem Mac des Nutzers. Bei größeren, mehrstufigen Aufträgen: zu Beginn state=running mit kurzem title und dem geplanten Ablauf als steps (Liste kurzer Schritt-Namen) senden; bei jedem neuen Schritt step (1-basiert) und detail (was gerade passiert) aktualisieren, optional progress (0–1); am Ende state=done mit einem kurzen detail zum Ergebnis (oder state=error). state=waiting, wenn eine Rückfrage an den Nutzer offen ist. Shows live task progress (with step list) in the Mac's notch island.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "state": ["type": "string", "enum": ["running", "waiting", "done", "error"], "description": "Status der Aufgabe"],
                "title": ["type": "string", "description": "Kurzer Titel, z. B. „Recherche Mietrecht“"],
                "detail": ["type": "string", "description": "Aktueller Schritt, z. B. „Lese Quelle 3 von 8“"],
                "progress": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fortschritt von 0 bis 1 (optional)"],
                "steps": ["type": "array", "items": ["type": "string"], "description": "Geplante Schritte, z. B. [\"Quellen suchen\", \"Lesen\", \"Bericht schreiben\"] (einmal zu Beginn)"],
                "step": ["type": "integer", "minimum": 1, "description": "Aktueller Schritt (1-basiert)"],
            ],
            "required": ["state"],
        ],
    ],
    [
        "name": "notch_toast",
        "description": "Zeigt eine kurze Mitteilung in der Notch des Macs (z. B. Erinnerung oder Ergebnis).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "subtitle": ["type": "string"],
                "icon": ["type": "string", "description": "Optional: Name eines SF Symbols, z. B. bell.fill"],
            ],
            "required": ["title"],
        ],
    ],
    [
        "name": "notch_timer",
        "description": "Startet einen Timer in der Notch des Macs.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "minutes": ["type": "number", "description": "Dauer in Minuten (Dezimalzahl möglich)"],
                "label": ["type": "string", "description": "Optionale Bezeichnung"],
            ],
            "required": ["minutes"],
        ],
    ],
]

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func reply(_ id: Any, _ result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func text(_ s: String, error: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": error]
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id = msg["id"] else { continue } // Benachrichtigungen ignorieren

    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "notch-island", "version": "1.0.0"],
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        var a = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "notch_status":
            a["kind"] = "claude"
            a["source"] = "mcp"
            post(a)
            reply(id, text("Notch aktualisiert (\(a["state"] as? String ?? "running"))."))
        case "notch_toast":
            a["kind"] = "toast"
            post(a)
            reply(id, text("Mitteilung angezeigt."))
        case "notch_timer":
            a["kind"] = "timer"
            post(a)
            reply(id, text("Timer gestartet."))
        default:
            reply(id, text("Unbekanntes Werkzeug: \(name)", error: true))
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
    }
}
