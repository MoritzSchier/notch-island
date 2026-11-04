import AppKit


/// Brings the terminal that runs a session back to the front.
///
/// The session's process is a child of the terminal application, so walking the
/// parent chain until an ancestor turns out to be a real app is enough. That
/// finds Ghostty, iTerm, Terminal.app, WezTerm, VS Code and anything else that
/// spawns its shells itself.
///
/// This raises the application, not the individual tab: tab-level focus needs a
/// scripting interface that most terminals do not offer.

enum TerminalFocus {
    @discardableResult
    static func activateApp(owning pid: Int) -> Bool {
        guard let app = owningApplication(of: pid) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// First ancestor that is a running application with a bundle. Plain shells,
    /// `login`, `tmux` and node wrappers have none and are skipped.
    static func owningApplication(of pid: Int) -> NSRunningApplication? {
        for ancestor in ProcessTree.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: pid_t(ancestor)),
               app.bundleIdentifier != nil {
                return app
            }
        }
        return nil
    }
}
