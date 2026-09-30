import Darwin
import Foundation

/// A program started in a session of its own, so that stopping it also stops everything it
/// started: a mini is a chain of programs (the 3D engine runs for minutes under a wrapper),
/// and Stop has to end the whole chain, not only the top of it.
///
/// Foundation's `Process` can't do this: it has no way to put the child in its own process
/// group. `posix_spawn` with `POSIX_SPAWN_SETSID` can.
public final class GroupProcess: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?

    /// Starts `executable` with exactly `environment` (nothing inherited: launched from the
    /// Dock, the app's own PATH is launchd's bare one) and output appended to `log`.
    /// `output` sends stdout and stderr to that file descriptor instead (the write end of a
    /// pipe; `closeInChild` is its read end). `newSession` is false only for a program that
    /// must stay in its parent's group, so that stopping the parent's group stops it too.
    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String? = nil, log: String? = nil,
                output: (fd: Int32, closeInChild: Int32)? = nil, newSession: Bool = true) throws {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if newSession { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let log {
            posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        }
        if let output {
            posix_spawn_file_actions_adddup2(&actions, output.fd, 1)
            posix_spawn_file_actions_adddup2(&actions, output.fd, 2)
            posix_spawn_file_actions_addclose(&actions, output.fd)
            posix_spawn_file_actions_addclose(&actions, output.closeInChild)
        }
        if let workingDirectory { posix_spawn_file_actions_addchdir(&actions, workingDirectory) }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL) }
        self.pid = pid
    }

    /// Blocks until the program ends. Returns its exit code, or minus the signal that ended it
    /// (-15 after Stop), the same convention the web version reported.
    @discardableResult
    public func wait() -> Int32 {
        if let status = lock.withLock({ status }) { return status }
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
        let code = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -(raw & 0x7f)
        lock.withLock { status = code }
        return code
    }

    /// Stops the program and everything it started: SIGTERM to the whole group, then SIGKILL
    /// to whatever is still there after `grace` seconds.
    public func terminateGroup(grace: TimeInterval = 5) {
        let group = newSessionGroup
        kill(group, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, groupAlive(group) { usleep(50_000) }
        if groupAlive(group) { kill(group, SIGKILL) }
    }

    /// With its own session the child leads a group whose id is its pid; -pid addresses it all.
    private var newSessionGroup: pid_t { -pid }

    private func groupAlive(_ group: pid_t) -> Bool {
        // The leader may already be a zombie waiting for wait(); anything else in the group
        // still counts. kill(…, 0) sends nothing and only asks whether anyone is there.
        kill(group, 0) == 0
    }
}
