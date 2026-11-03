import Foundation

/// One entry of Claude Code's own session register in `~/.claude/sessions/<pid>.json`.
/// It carries the session name, the real process id and how the session was started.
struct RegistryEntry: Sendable, Equatable {
    var sessionId: String
    var pid: Int
    var name: String?
    var kind: String?
    var entrypoint: String?
    var cwd: String?
    var startedAt: Double?

    /// Sessions started programmatically (claude-mem observers and other SDK
    /// runs) are not terminals the user sits in front of.
    var isRealTerminal: Bool {
        entrypoint != "sdk-cli"
    }

    /// A terminal window the user has open, as opposed to a background task.
    var isInteractive: Bool {
        kind == "interactive"
    }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "?" }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (trimmed as NSString).lastPathComponent
    }

    /// `startedAt` is milliseconds since the epoch.
    var startedDate: Date? {
        guard let startedAt, startedAt > 0 else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }

    var isAlive: Bool {
        SessionLoader.processIsAlive(pid)
    }
}

enum SessionRegistry {
    /// Reads the register and keeps, per session id, the newest entry whose
    /// process is still alive. Falls back to the newest entry overall.
    ///
    /// Prewarmed helper processes register themselves like a background job,
    /// so they are dropped by their command line before anything else.
    static func load(
        directory: URL = NotchPaths.claudeSessions,
        isHelper: (Int) -> Bool = ProcessArguments.isHelperProcess
    ) -> [String: RegistryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var best: [String: RegistryEntry] = [:]

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = object["sessionId"] as? String,
                  let pid = object["pid"] as? Int
            else { continue }

            if isHelper(pid) { continue }

            let entry = RegistryEntry(
                sessionId: sessionId,
                pid: pid,
                name: object["name"] as? String,
                kind: object["kind"] as? String,
                entrypoint: object["entrypoint"] as? String,
                cwd: object["cwd"] as? String,
                startedAt: object["startedAt"] as? Double
            )

            guard let existing = best[sessionId] else {
                best[sessionId] = entry
                continue
            }
            if isBetter(entry, than: existing) { best[sessionId] = entry }
        }

        return best
    }

    /// A live process wins, otherwise the later start wins.
    static func isBetter(_ candidate: RegistryEntry, than existing: RegistryEntry) -> Bool {
        let candidateAlive = candidate.isAlive
        if candidateAlive != existing.isAlive { return candidateAlive }
        return (candidate.startedAt ?? 0) > (existing.startedAt ?? 0)
    }
}
