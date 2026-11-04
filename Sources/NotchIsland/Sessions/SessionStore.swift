import Foundation
import Combine

/// Watches the hook's state files and publishes one traffic light per live Claude Code session.
///
/// The status comes from `~/.claude/notch/notch-hook.py`. On top of that, a request that is
/// waiting in the notch (permission or question) turns its session red, because the hook
/// holds the terminal prompt back while the notch asks.
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [ClaudeSession] = []
    /// Finished turns the user has already looked at. They turn grey.
    @Published private(set) var acknowledged: Set<String> = []

    private let directory: URL
    private let transcripts = TranscriptReader()
    private var watcher: DirectoryWatcher?
    private var refreshTimer: Timer?
    private var bag = Set<AnyCancellable>()

    init(directory: URL = NotchPaths.sessionsDirectory) {
        self.directory = directory
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reload() }
        // Safety net: drops closed sessions and heals stale red even without events.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.reload() }
        // A request appearing or disappearing in the notch changes the colours.
        ClaudeService.shared.$pendingSessions
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
            .store(in: &bag)
    }

    func reload() {
        let pending = ClaudeService.shared.pendingSessions
        let loaded = SessionLoader.load(directory: directory, registry: SessionRegistry.load()).map { raw in
            var session = SessionLoader.heal(raw, transcriptActivity: transcripts.lastActivity(for: raw.sessionId))
            session.activity = transcripts.lastPrompt(for: session.sessionId)
            session.tool = transcripts.lastTool(for: session.sessionId)
            if pending.contains(session.sessionId) { session.status = .blocked }
            return session
        }
        let sorted = SessionLoader.sort(loaded)
        if sorted != sessions { sessions = sorted }
        let live = Set(sorted.map(SessionLoader.attentionKey(for:)))
        let kept = acknowledged.intersection(live)
        if kept != acknowledged { acknowledged = kept }
    }

    /// What the dot shows: an acknowledged finished turn falls back to grey.
    func displayStatus(_ s: ClaudeSession) -> SessionStatus {
        if s.status == .done && acknowledged.contains(SessionLoader.attentionKey(for: s)) { return .ready }
        return s.status
    }

    /// The compact notch only shows the dots while something is going on.
    var hasActivity: Bool {
        sessions.contains { displayStatus($0) != .ready }
    }

    func acknowledge(_ s: ClaudeSession) {
        guard s.status == .done else { return }
        acknowledged.insert(SessionLoader.attentionKey(for: s))
    }

    func acknowledgeAll() {
        for s in sessions where s.status == .done { acknowledge(s) }
    }

    /// Click on a session: show its open request, otherwise bring its terminal forward.
    func open(_ s: ClaudeSession) {
        acknowledge(s)
        if ClaudeService.shared.showPending(for: s.sessionId) { return }
        if let pid = SessionRegistry.load()[s.sessionId]?.pid {
            TerminalFocus.activateApp(owning: pid)
        }
    }
}

/// Minimal vnode watcher for a single directory.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { onChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
