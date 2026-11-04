import Foundation

/// Reads the command line of a running process.
///
/// Claude Code keeps prewarmed helper processes around (`claude bg-spare`,
/// `claude bg-pty-host`). They register themselves like a real background job,
/// so only their arguments tell them apart from a session the user started.
enum ProcessArguments {
    /// Executable path and arguments, space separated. Empty when the process
    /// is gone or belongs to someone else.
    static func commandLine(pid: Int) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return ""
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }

        // Layout: argc as Int32, then the executable path and the arguments,
        // each NUL terminated and padded with further NUL bytes.
        let payload = buffer.prefix(size).dropFirst(MemoryLayout<Int32>.size)
        return payload
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: " ")
    }

    /// True for the prewarmed helpers that must never show up as a session.
    static func isHelperProcess(pid: Int) -> Bool {
        let line = commandLine(pid: pid)
        return line.contains("bg-spare") || line.contains("bg-pty-host")
    }
}
