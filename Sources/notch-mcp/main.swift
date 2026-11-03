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
    let wanted: [(String, String, Int?)] = [("UserPromptSubmit", "running", nil), ("Notification", "waiting", nil),
                                           ("Stop", "done", nil), ("PermissionRequest", "permission", 600)]
    for (event, arg, timeout) in wanted {
        var list = hooks[event] as? [[String: Any]] ?? []
        // alte Einträge von Notch Island entfernen, dann neu eintragen
        list = list.filter { group in
            let hs = group["hooks"] as? [[String: Any]] ?? []
            return !hs.contains { ($0["command"] as? String ?? "").contains("notch-mcp") }
        }
        var h: [String: Any] = ["type": "command", "command": "\(cmd) --hook \(arg)"]
        if let timeout { h["timeout"] = timeout }
        list.append(["hooks": [h]])
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

// Claude Code „PermissionRequest“-Hook: Frage in der Insel zeigen und auf die Antwort warten.
// Antwortet niemand (oder „Im Terminal“), gibt der Hook nichts aus → Claude Code fragt wie gewohnt im Terminal.
if args.contains("--hook"), args.contains("permission") {
    var input: [String: Any] = [:]
    if isatty(fileno(stdin)) == 0 {
        input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]) ?? [:]
    }
    let tool = input["tool_name"] as? String ?? "ein Werkzeug"
    let ti = input["tool_input"] as? [String: Any] ?? [:]
    let what = (ti["command"] as? String) ?? (ti["file_path"] as? String) ?? (ti["url"] as? String) ?? (ti["description"] as? String) ?? ""
    let project = (input["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
    let id = UUID().uuidString
    var decision: String?
    let replyName = Notification.Name("notchisland.reply")
    let obs = DistributedNotificationCenter.default().addObserver(forName: replyName, object: nil, queue: nil) { n in
        guard let s = n.object as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              d["id"] as? String == id else { return }
        decision = d["decision"] as? String
    }
    post(["kind": "permission", "id": id,
          "title": "Claude Code möchte „\(tool)“ verwenden" + (project.map { " · \($0)" } ?? ""),
          "detail": String(what.prefix(160))])
    let deadline = Date().addingTimeInterval(590)
    while decision == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    DistributedNotificationCenter.default().removeObserver(obs)
    guard let decision, decision == "allow" || decision == "deny" else {
        post(["kind": "permission_cancel", "id": id])
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        exit(0)   // keine Entscheidung → normale Abfrage im Terminal
    }
    var dec: [String: Any] = ["behavior": decision]
    if decision == "deny" { dec["message"] = "In der Notch abgelehnt" }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": dec]]
    if let data = try? JSONSerialization.data(withJSONObject: out) {
        FileHandle.standardOutput.write(data)
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
