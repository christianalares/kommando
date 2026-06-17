//
//  TerminalSession.swift
//  Kommando
//
//  Owns a live SwiftTerm LocalProcessTerminalView (the PTY + emulator) for one pane.
//  The session outlives SwiftUI view updates so the shell process is never torn down
//  on a re-render. Sessions are cached by leaf id in `SessionRegistry`.
//

import AppKit
import Darwin
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: String
    let terminalView: KommandoTerminalView

    /// JSON values detected in the currently-visible terminal output.
    var jsonMatches: [JSONMatch] = []

    /// ⌘F find bar state for this pane.
    var findVisible = false
    var findTerm = ""
    /// Bumped to re-focus the find field when ⌘F is pressed while it's already open.
    var findFocusToken = 0

    private(set) var hasStarted = false
    private(set) var isTerminated = false

    /// Reported by the shell via OSC 7 / OSC 1337; used as the cwd for AI context.
    var currentDirectory: String?
    /// Directory to start the shell in once the pane mounts (inherited from the pane
    /// the user split/opened from). Falls back to home when nil.
    var startDirectory: String?
    /// Latest terminal title reported by the shell.
    var title: String = "Shell"

    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    var onProcessTerminated: ((Int32?) -> Void)?

    private var bridge: ProcessBridge?

    init(id: String = UUID().uuidString) {
        self.id = id
        terminalView = KommandoTerminalView(frame: .zero)
        let bridge = ProcessBridge(owner: self)
        self.bridge = bridge
        terminalView.processDelegate = bridge
        // Compose Option-key characters (e.g. ⌥7 → "|" on Nordic layouts) instead of
        // treating Option as Meta, matching macOS Terminal's default.
        terminalView.optionAsMetaKey = false
        terminalView.onContentChange = { [weak self] in
            self?.rescanJSON()
            self?.checkDirectoryChange()
        }
        TerminalTheming.apply(SettingsStore.shared, to: terminalView)
    }

    func applyTheme() {
        TerminalTheming.apply(SettingsStore.shared, to: terminalView)
    }

    // MARK: - Find

    private var searchOptions: SearchOptions { SearchOptions(caseSensitive: false) }

    func findNext() {
        guard !findTerm.isEmpty else {
            terminalView.clearSearch()
            return
        }
        terminalView.findNext(findTerm, options: searchOptions)
    }

    func findPrevious() {
        guard !findTerm.isEmpty else { return }
        terminalView.findPrevious(findTerm, options: searchOptions)
    }

    func clearFind() {
        terminalView.clearSearch()
    }

    /// A plain-text snapshot of the terminal's visible screen, used as AI context.
    /// Leading/trailing blank lines are trimmed; output is capped to `maxLines`.
    func snapshotOutput(maxLines: Int = 200) -> String {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        guard rows > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        return lines.joined(separator: "\n")
    }

    func rescanJSON() {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        guard rows > 0 else { return }
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        jsonMatches = JSONDetector.detect(visibleLines: lines)
    }

    func startIfNeeded(cwd: String? = nil) {
        guard !hasStarted else { return }
        hasStarted = true

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let directory = cwd ?? startDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: Self.makeEnvironment(),
            execName: nil,
            currentDirectory: directory
        )
    }

    /// Best-effort current working directory: the live cwd of the running shell
    /// process, falling back to the OSC 7 directory reported by the shell.
    var resolvedDirectory: String? {
        if hasStarted, let pid = terminalView.process?.shellPid, pid > 0,
           let cwd = Self.cwd(forPid: pid) {
            return cwd
        }
        if let currentDirectory, !currentDirectory.isEmpty {
            return currentDirectory
        }
        if let startDirectory, !startDirectory.isEmpty {
            return startDirectory
        }
        return nil
    }

    private var lastKnownDirectory: String?

    /// Polls the live shell process's cwd (ground truth) and fires `onDirectoryChange`
    /// when it changes. Needed because many shell configs don't emit OSC 7 on `cd`.
    func checkDirectoryChange() {
        guard hasStarted, let pid = terminalView.process?.shellPid, pid > 0,
              let cwd = Self.cwd(forPid: pid), cwd != lastKnownDirectory else {
            return
        }
        lastKnownDirectory = cwd
        currentDirectory = cwd
        onDirectoryChange?(cwd)
    }

    private static func cwd(forPid pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let ptr = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: ptr)
        }
        return path.isEmpty ? nil : path
    }

    /// Insert text into the shell's stdin without executing it (no trailing newline),
    /// matching the Glaze app's non-executing AI command insertion.
    func insertWithoutExecuting(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Runs a command as if it were entered *before* whatever the user has half-typed.
    ///
    /// Without this, executing a command (e.g. ⌘K → `clear`) while the input line already
    /// holds unentered text would concatenate them (`echo "hi"clear`). We send zsh's
    /// `push-line` widget (ESC-q) first, which stashes and clears the current buffer; zsh
    /// then automatically restores the stashed line at the next prompt, after our command
    /// has run. On an empty buffer it's a harmless round-trip. (zsh is macOS's default shell;
    /// other shells simply ignore the unbound ESC-q sequence.)
    func executeCommand(_ text: String) {
        terminalView.send(txt: "\u{1b}q")
        terminalView.send(txt: text + "\r")
    }

    func terminate() {
        guard hasStarted, !isTerminated else { return }
        isTerminated = true
        terminalView.terminate()
    }

    /// Marks the session terminated when the shell exits on its own (not via `terminate()`).
    func markTerminated() {
        isTerminated = true
    }

    private static func makeEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Blank zsh's partial-line indicator (inverted "%"), same trick as the Glaze build.
        env["PROMPT_EOL_MARK"] = ""
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// Bridges SwiftTerm's process delegate callbacks back to the owning session.
@MainActor
private final class ProcessBridge: LocalProcessTerminalViewDelegate {
    unowned let owner: TerminalSession

    init(owner: TerminalSession) {
        self.owner = owner
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner.title = title
        owner.onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        owner.currentDirectory = directory
        owner.onDirectoryChange?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner.markTerminated()
        owner.onProcessTerminated?(exitCode)
    }
}
