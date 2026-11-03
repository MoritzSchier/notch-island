import Foundation

/// Filesystem locations used by the Claude status layer.
enum NotchPaths {
    static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var notchHome: URL {
        claudeHome.appendingPathComponent("notch")
    }

    static var sessionsDirectory: URL {
        notchHome.appendingPathComponent("sessions")
    }

    /// Claude Code's own session register.
    static var claudeSessions: URL {
        claudeHome.appendingPathComponent("sessions")
    }

    /// Where Claude Code keeps the transcripts, one directory per project.
    static var claudeProjects: URL {
        claudeHome.appendingPathComponent("projects")
    }

    static var hookScript: URL {
        notchHome.appendingPathComponent("notch-hook.py")
    }

    static var claudeSettings: URL {
        claudeHome.appendingPathComponent("settings.json")
    }

}

/// Reads session state files written by the hook script.
/// Pure and side-effect free apart from reading (and pruning) files, so it is testable.
enum SessionLoader {
    /// True when a process with this id still exists.
    static func processIsAlive(_ pid: Int) -> Bool {
        // EPERM means the process exists but belongs to someone else.
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Builds the visible list from two sources.
    ///
    /// A session shows up once it has reported something itself, which is what
    /// separates a session in use from an old terminal tab where a `claude`
    /// process merely still exists. Claude Code's register adds the title and
    /// the real start time on top.
    ///
    /// The register decides who is alive: Claude Code writes an entry for every
    /// session and removes it when the session exits, so a missing or dead entry
    /// means the terminal is gone and the state file is deleted. An idle session
    /// stays as long as its process lives, no matter how long it has been quiet.
    /// Programmatic SDK runs never show up.
    static func load(
        directory: URL,
        registry: [String: RegistryEntry] = [:],
        now: Date = Date(),
        pruneStaleFiles: Bool = true,
        isAlive: (Int) -> Bool = processIsAlive
    ) -> [ClaudeSession] {
        let fm = FileManager.default
        let decoder = SessionCoding.decoder()
        let files = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var states: [String: ClaudeSession] = [:]

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(ClaudeSession.self, from: data)
            else {
                // Unreadable or half-written file: ignore this round, do not delete.
                continue
            }

            // No register entry, or a dead one: the session is over.
            guard let known = registry[session.sessionId], isAlive(known.pid) else {
                if pruneStaleFiles { try? fm.removeItem(at: url) }
                continue
            }
            states[session.sessionId] = session
        }

        var sessions: [ClaudeSession] = []

        for (sessionId, state) in states {
            // Every surviving state file has a live register entry.
            guard let entry = registry[sessionId], entry.isRealTerminal else { continue }
            var session = state
            session.title = entry.name
            if let started = entry.startedDate { session.startedAt = started }
            sessions.append(session)
        }

        // Background tasks are deliberately started jobs, not forgotten tabs, so
        // they are listed even before they report anything of their own.
        for (sessionId, entry) in registry
        where entry.isRealTerminal && !entry.isInteractive
            && states[sessionId] == nil && isAlive(entry.pid) {
            sessions.append(
                ClaudeSession(
                    sessionId: sessionId,
                    status: .ready,
                    project: entry.project,
                    cwd: entry.cwd ?? "",
                    startedAt: entry.startedDate ?? now,
                    updatedAt: entry.startedDate ?? now,
                    title: entry.name
                )
            )
        }

        return sort(sessions)
    }

    /// How far the transcript must be ahead of the block before it counts.
    /// The blocking write and the hook happen within the same moment.
    static let healGrace: TimeInterval = 2

    /// Lets a blocked session heal itself.
    ///
    /// Answering a permission prompt or a question fires no hook at all: the
    /// user typed nothing, so `UserPromptSubmit` stays silent. The state file
    /// would sit on `blocked` until the next `Stop`. Main-thread activity after
    /// the block is proof that the session moved on.
    static func heal(_ session: ClaudeSession, transcriptActivity: Date?) -> ClaudeSession {
        guard session.status == .blocked,
              let activity = transcriptActivity,
              activity > session.updatedAt.addingTimeInterval(healGrace)
        else { return session }

        var healed = session
        healed.status = .working
        // The question is answered, so its text must not linger in the UI.
        healed.message = nil
        healed.updatedAt = activity
        return healed
    }

    /// Attention first, then oldest session first. The second criterion is the
    /// start time on purpose: the dots must not shuffle on every status update.
    static func sort(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.sorted { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.sessionId < rhs.sessionId
        }
    }

    /// Identity of a single attention event, used to remember acknowledgements.
    static func attentionKey(for session: ClaudeSession) -> String {
        "\(session.sessionId)|\(session.status.rawValue)|\(Int(session.updatedAt.timeIntervalSince1970))"
    }
}
