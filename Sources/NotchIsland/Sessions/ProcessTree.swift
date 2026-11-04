import Foundation

/// Walks the parent chain of a running process.
///
/// A `claude` process sits a few levels below the terminal that owns it, for
/// example `claude → zsh → login → Ghostty`. Under tmux or a task runner the
/// chain looks different, which is why the caller decides where to stop.
enum ProcessTree {
    /// Parent process id, or nil when the process is gone or is `launchd`.
    static func parent(of pid: Int) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = Int(info.kp_eproc.e_ppid)
        return parent > 1 ? parent : nil
    }

    /// The parent chain, closest ancestor first. Stops at `launchd` and after
    /// `limit` steps, so a broken chain can never spin.
    static func ancestors(
        of pid: Int,
        limit: Int = 12,
        parent: (Int) -> Int? = parent(of:)
    ) -> [Int] {
        var chain: [Int] = []
        var current = pid
        var seen: Set<Int> = [pid]
        while chain.count < limit, let next = parent(current), !seen.contains(next) {
            chain.append(next)
            seen.insert(next)
            current = next
        }
        return chain
    }
}
