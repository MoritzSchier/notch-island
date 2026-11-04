import Foundation

/// Reads what a session is actually working on: its most recent user prompt,
/// taken from the tail of the transcript.
///
/// Only the last chunk of the file is read and the result is cached per
/// modification date, so this stays cheap even on multi-megabyte transcripts.
final class TranscriptReader {
    private struct CacheEntry {
        var modified: Date
        var prompt: String?
        var activity: Date?
        var tool: String?
    }

    private let projectsDirectory: URL
    private let tailBytes: Int
    private var cache: [String: CacheEntry] = [:]
    private var pathCache: [String: URL] = [:]

    init(
        projectsDirectory: URL = NotchPaths.claudeProjects,
        tailBytes: Int = 96 * 1024
    ) {
        self.projectsDirectory = projectsDirectory
        self.tailBytes = tailBytes
    }

    /// Latest user prompt of that session, trimmed to one line.
    func lastPrompt(for sessionId: String) -> String? {
        entry(for: sessionId)?.prompt
    }

    /// When the main conversation last wrote something. Subagent entries do not
    /// count: they keep running while the main session waits for an answer.
    func lastActivity(for sessionId: String) -> Date? {
        entry(for: sessionId)?.activity
    }

    /// Latest tool call of the main thread, e.g. "Bash · npm test".
    func lastTool(for sessionId: String) -> String? {
        entry(for: sessionId)?.tool
    }

    /// One parse per transcript change serves both readers.
    private func entry(for sessionId: String) -> CacheEntry? {
        guard let url = transcriptURL(for: sessionId) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        if let cached = cache[sessionId], cached.modified == modified {
            return cached
        }

        let tail = readTail(of: url)
        let fresh = CacheEntry(
            modified: modified,
            prompt: Self.extractLastPrompt(from: tail),
            activity: Self.extractLastActivity(from: tail),
            tool: Self.extractLastTool(from: tail)
        )
        cache[sessionId] = fresh
        return fresh
    }

    private func transcriptURL(for sessionId: String) -> URL? {
        if let known = pathCache[sessionId], FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for project in projects {
            let candidate = project.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                pathCache[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func readTail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Walks the lines backwards and returns the first real user prompt.
    static func extractLastPrompt(from tail: String) -> String? {
        for line in tail.components(separatedBy: "\n").reversed() {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "user",
                  entry["isMeta"] as? Bool != true,
                  entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any],
                  let text = text(from: message["content"]),
                  let cleaned = clean(text)
            else { continue }
            return cleaned
        }
        return nil
    }

    /// Walks the lines backwards and returns the newest main-thread timestamp.
    static func extractLastActivity(from tail: String) -> Date? {
        for line in tail.components(separatedBy: "\n").reversed() {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["isSidechain"] as? Bool != true,
                  let stamp = entry["timestamp"] as? String,
                  let date = timestamp(from: stamp)
            else { continue }
            return date
        }
        return nil
    }

    /// Walks the lines backwards and describes the newest main-thread tool call.
    /// A real user prompt after it means the call belongs to an older turn.
    static func extractLastTool(from tail: String) -> String? {
        for line in tail.components(separatedBy: "\n").reversed() {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any]
            else { continue }
            let type = entry["type"] as? String
            if type == "user", entry["isMeta"] as? Bool != true,
               let text = text(from: message["content"]), clean(text) != nil {
                return nil
            }
            guard type == "assistant", let parts = message["content"] as? [[String: Any]] else { continue }
            for part in parts.reversed() where part["type"] as? String == "tool_use" {
                let name = part["name"] as? String ?? "Tool"
                let input = part["input"] as? [String: Any] ?? [:]
                return describe(tool: name, input: input)
            }
        }
        return nil
    }

    static func describe(tool name: String, input: [String: Any]) -> String {
        var arg = ""
        for key in ["description", "command", "file_path", "pattern", "url", "query", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty { arg = v; break }
        }
        if let path = input["file_path"] as? String, !path.isEmpty { arg = (path as NSString).lastPathComponent }
        let flat = arg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let short = flat.count > 70 ? String(flat.prefix(70)) + "…" : flat
        return short.isEmpty ? name : "\(name) · \(short)"
    }

    /// Claude Code writes fractional seconds, older lines may not have them.
    private static func timestamp(from string: String) -> Date? {
        for formatter in [withFractions, withoutFractions] {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    // Configured once and only read from here on, which is safe to share.
    nonisolated(unsafe) private static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFractions = ISO8601DateFormatter()

    private static func text(from content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        for part in parts where part["type"] as? String == "text" {
            if let text = part["text"] as? String { return text }
        }
        return nil
    }

    /// Tool results, command wrappers and system notes are not what the user typed.
    private static func clean(_ text: String) -> String? {
        let skipMarkers = [
            "<local-command",
            "<command-name>",
            "[MESSAGE FROM NON-USER SOURCE",
            "<system-reminder>",
            "<task-notification>",
            "Caveat:",
            "tool_result",
        ]
        if skipMarkers.contains(where: text.contains) { return nil }

        let flattened = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}
