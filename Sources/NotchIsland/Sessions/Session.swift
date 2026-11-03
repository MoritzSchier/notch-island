import Foundation

/// Traffic light state of a Claude Code session, derived from hook events.
enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case ready
    case working
    case blocked
    case done

    /// Statuses that stay visible until the user has acknowledged them.
    var wantsAttention: Bool {
        self == .blocked || self == .done
    }

    /// Sort weight so attention-worthy sessions come first.
    var priority: Int {
        switch self {
        case .blocked: return 0
        case .done: return 1
        case .working: return 2
        case .ready: return 3
        }
    }

    var label: String {
        switch self {
        case .ready: return "ready"
        case .working: return "working"
        case .blocked: return "blocked"
        case .done: return "done"
        }
    }

    /// Maps a Claude Code hook event name to a status.
    /// Returns nil for events that must not change the traffic light.
    static func from(hookEvent: String) -> SessionStatus? {
        switch hookEvent {
        case "SessionStart": return .ready
        case "UserPromptSubmit": return .working
        case "Notification": return .blocked
        case "Stop": return .done
        default: return nil
        }
    }
}

/// One monitored Claude Code session, as written by the hook script.
struct ClaudeSession: Codable, Sendable, Identifiable, Equatable {
    var sessionId: String
    var status: SessionStatus
    var project: String
    var cwd: String
    var message: String?
    var startedAt: Date
    var updatedAt: Date
    /// Number of subagents still running. A finished main turn with open
    /// subagents stays yellow.
    var subagents: Int?
    /// Session title from Claude Code's register, filled in by the loader.
    var title: String?
    /// What the session is working on: its latest prompt, filled in by the store.
    var activity: String?
    /// Latest tool call of the main thread, filled in by the store.
    var tool: String?

    /// What the UI shows: the session title, folder name as fallback.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return project
    }

    var id: String { sessionId }

    init(
        sessionId: String,
        status: SessionStatus,
        project: String,
        cwd: String,
        message: String? = nil,
        startedAt: Date,
        updatedAt: Date,
        subagents: Int? = nil,
        title: String? = nil
    ) {
        self.sessionId = sessionId
        self.status = status
        self.project = project
        self.cwd = cwd
        self.message = message
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.title = title
    }

    /// Short, stable label for the UI.
    var shortId: String { String(sessionId.prefix(6)) }

    func runtime(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }
}

enum SessionCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Formats a runtime for the compact UI (e.g. "42s", "4m", "1h12m", "13d7h").
func formatRuntime(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
}
