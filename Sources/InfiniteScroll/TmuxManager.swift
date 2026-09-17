import Foundation

enum TmuxManager {
    static let prefix = "is-"
    /// Native and tmux scrollback use one bounded limit. A finite buffer keeps
    /// long-running Codex sessions scrollable without unbounded memory growth.
    /// The Settings picker offers `historyLimitOptions`; the clamp bounds derive
    /// from that list so the picker and the clamp cannot drift apart.
    static let historyLimitOptions = [1_000, 10_000, 50_000, 100_000]
    static let defaultHistoryLimit = 10_000
    static let minHistoryLimit = historyLimitOptions.first ?? 1_000
    static let maxHistoryLimit = historyLimitOptions.last ?? 100_000
    private static let cacheLock = NSLock()
    private static var _cachedPath: String?
    private static var _checked = false

    /// Resolve the tmux path on a background queue and cache it. Safe to call
    /// from anywhere (idempotent, locked). Call early in app launch so that
    /// `cachedTmuxPath()` returns a value by the time a terminal is mounted.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = findTmux()
        }
    }

    /// Non-blocking accessor — returns the cached path if resolved, else nil.
    /// Use this on the main thread (e.g. inside `makeNSView`) to avoid
    /// spinning a nested run loop during SwiftUI layout.
    static func cachedTmuxPath() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _checked ? _cachedPath : nil
    }

    /// Find a working tmux binary — verifies it actually runs.
    /// Blocks the calling thread; do not call from the main thread.
    @discardableResult
    static func findTmux() -> String? {
        cacheLock.lock()
        if _checked {
            let cached = _cachedPath
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let systemCandidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        var searchPaths: [String] = []
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("tmux").path {
            searchPaths.append(bundlePath)
        }
        searchPaths.append(contentsOf: systemCandidates)

        var resolved: String?
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) && verifyTmux(path) {
                resolved = path
                break
            }
        }

        cacheLock.lock()
        _cachedPath = resolved
        _checked = true
        cacheLock.unlock()
        return resolved
    }

    /// Actually run `tmux -V` to verify it works (dylibs load, etc.)
    private static func verifyTmux(_ path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-V"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func sessionName(for id: UUID) -> String {
        "\(prefix)\(id.uuidString)"
    }

    static func sessionExists(_ name: String) -> Bool {
        guard let tmux = findTmux() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["has-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func killSession(_ name: String) {
        guard let tmux = findTmux() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["kill-session", "-t", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    static func listSessions() -> [String] {
        guard let tmux = findTmux() else { return [] }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["list-sessions", "-F", "#{session_name}"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Read before waiting so a large list cannot fill the pipe and
            // deadlock the child.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return output.components(separatedBy: "\n")
                .filter { $0.hasPrefix(prefix) }
        } catch { return [] }
    }

    static func paneCwd(session: String) -> String? {
        guard let tmux = findTmux() else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["display-message", "-p", "-t", session, "-F", "#{pane_current_path}"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            return output
        } catch { return nil }
    }

    /// Capture a pane's visible contents plus, when requested, its retained
    /// scrollback. This must run off the main thread because it launches tmux
    /// and waits for its output.
    static func capturePane(session: String, scrollback: Int? = nil) -> Data? {
        let startLine = scrollback.flatMap { $0 > 0 ? "-\($0)" : nil }
        return capturePane(session: session, startLine: startLine, endLine: nil)
    }

    /// Capture only the history portion of a pane. Line zero is the top of the
    /// visible pane in tmux, so ending at -1 deliberately leaves the current
    /// screen for the attaching client to redraw instead of duplicating it.
    /// `-J` joins soft-wrapped rows back into logical lines so SwiftTerm can
    /// re-wrap them at the current width, and `-e` keeps SGR/hyperlink
    /// sequences so restored history is not monochrome.
    static func capturePaneHistory(session: String, limit: Int = defaultHistoryLimit) -> Data? {
        guard limit > 0 else { return nil }
        return capturePane(
            session: session,
            startLine: "-\(limit)",
            endLine: "-1",
            joinWrappedLines: true,
            includeEscapeSequences: true
        )
    }

    /// Reads the currently visible pane only. Callers must treat the returned
    /// text as ephemeral: it is suitable for local status inference, never for
    /// persistence or diagnostics.
    static func visiblePaneText(session: String) -> String? {
        guard let data = capturePane(
            session: session,
            startLine: nil,
            endLine: nil,
            joinWrappedLines: true
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func capturePane(
        session: String,
        startLine: String?,
        endLine: String?,
        joinWrappedLines: Bool = false,
        includeEscapeSequences: Bool = false
    ) -> Data? {
        guard let tmux = findTmux() else { return nil }
        var args = ["capture-pane", "-p"]
        if joinWrappedLines {
            args.append("-J")
        }
        if includeEscapeSequences {
            args.append("-e")
        }
        args += ["-t", session]
        if let startLine {
            args += ["-S", startLine]
        }
        if let endLine {
            args += ["-E", endLine]
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Read before waiting so a large scrollback cannot fill the pipe
            // and deadlock the child process.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Run a tmux command (fire-and-forget)
    @discardableResult
    static func run(_ args: [String]) -> Bool {
        guard let tmux = findTmux() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch { return false }
    }

    private static var _configuredGlobals = false
    private static let globalsLock = NSLock()

    /// Configure global tmux input settings. Mouse handling is configured per
    /// Infinite Scroll session so unrelated tmux sessions keep their own setup.
    static func configureGlobals() {
        globalsLock.lock()
        defer { globalsLock.unlock() }
        guard !_configuredGlobals else { return }
        // `set-option` cannot start a tmux server, so on a cold start these
        // fail until the first session exists. Latch the flag only on success
        // so the next terminal (or session attach) retries instead of losing
        // extended-keys/TERM_PROGRAM for the whole app lifetime.
        let applied = run(["set-option", "-g", "extended-keys", "on"])
            && run(["set-option", "-g", "extended-keys-format", "csi-u"])
            // Propagate TERM_PROGRAM into sessions on (re)attach
            && run(["set-option", "-g", "update-environment", "TERM_PROGRAM"])
        if applied {
            _configuredGlobals = true
        }
    }

    /// Keep app-managed panes in SwiftTerm's local scrollback and remove tmux
    /// chrome that is not useful inside the app. These are session options, so
    /// they do not alter the user's other tmux sessions.
    static func configureSession(_ session: String, historyLimit: Int) {
        // LocalProcessTerminalView starts `tmux new-session` asynchronously.
        // Wait briefly for a newly-created session so it cannot miss these
        // per-session settings.
        for attempt in 0..<20 {
            if configureExistingSession(session, historyLimit: historyLimit) {
                return
            }
            if attempt < 19 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Apply pane settings immediately when reattaching to a session that
    /// already exists. Returns false for new sessions so callers can avoid the
    /// retry loop used by `configureSession`.
    @discardableResult
    static func configureExistingSession(_ session: String, historyLimit: Int) -> Bool {
        guard sessionExists(session) else { return false }
        // The server now exists, so this is the first chance to apply global
        // options after a cold start.
        configureGlobals()
        _ = run(["set-option", "-q", "-t", session, "history-limit", "\(historyLimit)"])
        _ = run(["set-option", "-q", "-t", session, "status", "off"])
        // Keep full-screen apps (Codex, opencode, vim, htop) on the pane's main
        // screen so their output lands in tmux history and can be restored by
        // hydration after an app restart. The outer client already runs without
        // an alternate screen thanks to the bundled terminfo.
        _ = run(["set-option", "-q", "-t", session, "alternate-screen", "off"])
        // The session's `mouse` option is owned by refreshMouseRouting, which
        // mirrors the pane application's own mouse mode.
        _ = run(["send-keys", "-t", session, "-X", "cancel"])
        return true
    }

    /// Resize a live pane's retained history after the user changes the
    /// scrollback setting. Must run off the main thread. Returns false when
    /// tmux rejects the change so the caller can surface it.
    static func setHistoryLimit(session: String, limit: Int) -> Bool {
        run(["set-option", "-q", "-t", session, "history-limit", "\(limit)"])
    }

    /// Detach every client attached to a session, leaving the session (and the
    /// programs running inside it) alive. Must run off the main thread.
    static func detachSession(_ session: String) {
        _ = run(["detach-client", "-s", session])
    }

    /// Whether the pane's application asked tmux to deliver mouse events
    /// (mouse_any_flag). Full-screen apps like opencode, Codex, vim, and htop
    /// set this when they want the wheel and clicks. Blocks the calling
    /// thread; run off-main.
    static func paneWantsMouse(session: String) -> Bool? {
        guard let tmux = findTmux() else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["display-message", "-p", "-t", session, "#{mouse_any_flag}"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            return mouseAnyFlag(from: output)
        } catch { return nil }
    }

    /// Parses a `#{mouse_any_flag}` reply. Pure so it can be verified with a
    /// standalone swiftc probe.
    static func mouseAnyFlag(from output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Enable or disable tmux mouse forwarding for one session. tmux only
    /// enables mouse reporting on the outer terminal while this is on, so the
    /// app keeps it off for plain shells and turns it on for panes whose
    /// applications want the mouse. Returns false when tmux rejects the change
    /// so callers can retry instead of caching a state that was never applied.
    static func setMouse(_ session: String, enabled: Bool) -> Bool {
        run(["set-option", "-q", "-t", session, "mouse", enabled ? "on" : "off"])
    }

    /// Send literal keys into a tmux pane, bypassing tmux's input parsing.
    /// Waits for the tmux client so callers can distinguish delivery failures
    /// from success; every call site already runs off the main thread.
    @discardableResult
    static func sendKeys(_ session: String, keys: [String]) -> Bool {
        guard let tmux = findTmux() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmux)
        task.arguments = ["send-keys", "-t", session] + keys
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return false }
        return task.terminationStatus == 0
    }

    static func cleanupOrphans(activeCellIDs: Set<UUID>) {
        let activeNames = Set(activeCellIDs.map { sessionName(for: $0) })
        for session in listSessions() {
            if !activeNames.contains(session) {
                killSession(session)
            }
        }
    }
}
