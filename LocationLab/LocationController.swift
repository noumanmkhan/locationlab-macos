import Foundation
import AppKit
import Combine

/// Runs a command to completion and returns (exit code, combined output).
nonisolated enum Shell {
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 30) async -> (Int32, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "Could not launch \(exe): \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Quote for a POSIX shell.
    static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Quote for an AppleScript string literal.
    static func applescript(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

@MainActor
final class LocationController: ObservableObject {
    static let shared = LocationController()

    enum Phase: Equatable { case idle, setting, active, clearing }

    @Published var phase: Phase = .idle
    @Published var activePlace: Place?
    @Published var tunnelRunning: Bool? = nil
    @Published var log: String = ""
    @Published var lastError: String?
    /// Set after a successful clear; the phone takes a little while to get a real GPS fix again.
    @Published var recentlyCleared = false
    private var clearedNoteTask: Task<Void, Never>?
    @Published var toolPath: String {
        didSet {
            UserDefaults.standard.set(toolPath, forKey: "toolPath")
            if toolPath != oldValue { toolVersion = nil }
        }
    }
    /// Shown in Setup/Settings, e.g. "11.56.1".
    @Published var toolVersion: String?
    /// True when pymobiledevice3 couldn't be found; the main window shows the setup sheet.
    @Published var needsSetup = false

    private var holder: Process?
    private var holderStdin: Pipe?
    private var holderOutput = ""
    private var pendingPlace: Place?
    private var expectingExit = false

    private init() {
        toolPath = UserDefaults.standard.string(forKey: "toolPath") ?? ""
        Task { await self.bootstrap() }
    }

    var toolReady: Bool { FileManager.default.isExecutableFile(atPath: toolPath) }
    var busy: Bool { phase == .setting || phase == .clearing }
    var hasHolder: Bool { holder?.isRunning == true }

    // MARK: - Setup

    func bootstrap() async {
        if !toolReady, let found = await Self.locateTool() {
            toolPath = found
            appendLog("Found pymobiledevice3 at \(found)\n")
        }
        if toolReady {
            await refreshToolVersion()
        } else {
            needsSetup = true
        }
        await refreshTunnel()
    }

    /// Reads `pymobiledevice3 version` (last line that looks like a version number).
    func refreshToolVersion() async {
        guard toolReady else { toolVersion = nil; return }
        let (code, out) = await Shell.run(toolPath, ["version"], timeout: 60)
        guard code == 0 else { toolVersion = nil; return }
        toolVersion = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.first?.isNumber == true && !$0.contains(" ") }
    }

    func autodetect() {
        Task {
            if let found = await Self.locateTool() {
                toolPath = found
                lastError = nil
                appendLog("Found pymobiledevice3 at \(found)\n")
                await refreshToolVersion()
            } else {
                lastError = "Couldn't find pymobiledevice3. In Terminal run `which pymobiledevice3` and paste the path in Settings."
            }
        }
    }

    static func locateTool() async -> String? {
        // A copy installed by LocationLab's own setup wins.
        if FileManager.default.isExecutableFile(atPath: SetupModel.managedTool) { return SetupModel.managedTool }
        // GUI apps don't inherit your shell PATH, so ask a login+interactive zsh.
        let (_, out) = await Shell.run("/bin/zsh", ["-ilc", "command -v pymobiledevice3"], timeout: 10)
        let fm = FileManager.default
        if let line = out.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.hasPrefix("/") }), fm.isExecutableFile(atPath: line) {
            return line
        }
        let home = NSHomeDirectory()
        var guesses = [
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
            "\(home)/.local/bin/pymobiledevice3",
        ]
        let pyRoot = "\(home)/Library/Python"
        if let versions = try? fm.contentsOfDirectory(atPath: pyRoot) {
            guesses += versions.sorted().reversed().map { "\(pyRoot)/\($0)/bin/pymobiledevice3" }
        }
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        if let versions = try? fm.contentsOfDirectory(atPath: frameworks) {
            guesses += versions.sorted().reversed().map { "\(frameworks)/\($0)/bin/pymobiledevice3" }
        }
        return guesses.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Simulate

    /// How long to wait for the CLI to either confirm (prints its "Press Ctrl+C…" hold prompt),
    /// exit 0 (versions that set and exit), or fail. Covers Python start-up + tunnel + DVT handshake.
    private static let setTimeout: TimeInterval = 25

    func simulate(_ place: Place) {
        guard !busy else { return }
        guard toolReady else {
            needsSetup = true
            return
        }
        phase = .setting
        lastError = nil
        recentlyCleared = false
        Task {
            await stopHolder()
            guard phase == .setting else { return }   // Stop & Clear was pressed meanwhile
            appendLog("\n→ \(place.name) (\(place.coordText))\n")

            let p = Process()
            p.executableURL = URL(fileURLWithPath: toolPath)
            p.arguments = ["developer", "dvt", "simulate-location", "set", "--",
                           String(place.lat), String(place.lon)]
            // Python block-buffers stdout into a pipe; we need its hold prompt as soon as it prints.
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["NO_COLOR"] = "1"
            p.environment = env
            // Keep stdin open: some CLI versions hold the location until they read Enter.
            let inPipe = Pipe()
            p.standardInput = inPipe
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = outPipe
            let pid = ObjectIdentifier(p)
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { LocationController.shared.holderOutput(pid, text) }
                }
            }
            p.terminationHandler = { proc in
                let code = proc.terminationStatus
                // Hop via main queue *after* any pending output blocks so the error text is complete.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { LocationController.shared.holderExited(pid, code: code) }
                }
            }
            do {
                try p.run()
            } catch {
                activePlace = nil
                phase = .idle
                lastError = "Couldn't launch pymobiledevice3: \(error.localizedDescription)"
                return
            }
            holder = p
            holderStdin = inPipe
            holderOutput = ""
            pendingPlace = place

            // Watchdog: never sit in "Setting…" forever (e.g. tunnel up but phone unreachable).
            try? await Task.sleep(nanoseconds: UInt64(Self.setTimeout * 1_000_000_000))
            if pendingPlace == place, let h = holder, ObjectIdentifier(h) == pid, phase == .setting {
                appendLog("\n(timed out after \(Int(Self.setTimeout))s)\n")
                await stopHolder()
                activePlace = nil
                phase = .idle
                lastError = "Timed out talking to the iPhone. Check it's connected and unlocked."
                    + (tunnelRunning == false ? " If this keeps happening, try starting tunneld (••• menu › Start tunneld)." : "")
                await refreshTunnel()
            }
        }
    }

    private func holderOutput(_ id: ObjectIdentifier, _ text: String) {
        appendLog(text)
        guard let h = holder, ObjectIdentifier(h) == id else { return }
        holderOutput += text
        // The holding variant prints this once the location has been set.
        let lower = holderOutput.lowercased()
        if phase == .setting, lower.contains("press ctrl+c") || lower.contains("press enter") {
            confirmPending()
        }
    }

    private func confirmPending() {
        guard let place = pendingPlace else { return }
        pendingPlace = nil
        activePlace = place
        phase = .active
    }

    private func holderExited(_ id: ObjectIdentifier, code: Int32) {
        guard let h = holder, ObjectIdentifier(h) == id else { return }
        let output = holderOutput
        holder = nil
        holderStdin = nil
        holderOutput = ""
        if expectingExit { return }
        if code == 0 {
            // This CLI version sets and exits; the location stays set.
            if phase == .setting { confirmPending() }
            return
        }
        pendingPlace = nil
        activePlace = nil
        phase = .idle
        lastError = Self.explain(output: output, code: code, tunnelRunning: tunnelRunning)
        Task { await refreshTunnel() }
    }

    private func stopHolder() async {
        guard let p = holder else { return }
        expectingExit = true
        if p.isRunning {
            // Current versions stop on SIGINT; older ones on Enter. Do both.
            try? holderStdin?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            p.interrupt()
            if !(await waitForExit(p, seconds: 3)) { p.terminate() }
            if !(await waitForExit(p, seconds: 2)) { kill(p.processIdentifier, SIGKILL) }
            _ = await waitForExit(p, seconds: 1)
        }
        try? holderStdin?.fileHandleForWriting.close()
        holder = nil
        holderStdin = nil
        holderOutput = ""
        pendingPlace = nil
        expectingExit = false
    }

    private func waitForExit(_ p: Process, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !p.isRunning
    }

    /// Turn pymobiledevice3's traceback / message into something a human can act on.
    static func explain(output: String, code: Int32, tunnelRunning: Bool?) -> String {
        let o = output.lowercased()
        // tunneld is optional; only suggest it for connection-type failures.
        let tunnelHint = tunnelRunning == false
            ? " If this keeps happening, try starting tunneld (••• menu › Start tunneld)." : ""
        if o.contains("passwordrequired") || o.contains("locked") {
            return "The iPhone is locked. Unlock it and try again."
        }
        if o.contains("developermode") || o.contains("developer mode") {
            return "Developer Mode is off on the iPhone. Turn it on in Settings › Privacy & Security › Developer Mode."
        }
        if o.contains("notpaired") || o.contains("nottrusted") || o.contains("pairingerror") {
            return "The iPhone isn't paired/trusted with this Mac. Connect via USB, unlock it and tap “Trust”."
        }
        if o.contains("tunneldconnection") || (o.contains("tunneld") && o.contains("refused")) {
            return "Can't reach tunneld. Stop and restart it from the tunneld menu, or stop it and try without it."
        }
        if o.contains("nodeviceconnected") || o.contains("devicenotfound") || o.contains("no device")
            || o.contains("not connected") || o.contains("device not found") {
            return "No iPhone found. Connect it by USB (or same Wi-Fi) and unlock it." + tunnelHint
        }
        if o.contains("notmounted") || o.contains("developerdiskimage") {
            return "The developer disk image isn't mounted. In Terminal run: pymobiledevice3 mounter auto-mount"
        }
        if o.contains("invalidservice") || o.contains("startservice") {
            return "The iPhone refused the location service. Make sure it's unlocked with Developer Mode on." + tunnelHint
        }
        // Prefer the CLI's own "… ERROR <message>" log line over its "run again with -v" hint.
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var last = lines.last(where: { $0.contains(" ERROR ") }) ?? lines.last(where: { !$0.isEmpty }) ?? ""
        if let r = last.range(of: " ERROR ") { last = String(last[r.upperBound...]) }
        let detail = last.isEmpty ? "" : " Last message: \(last)"
        return "pymobiledevice3 failed (exit \(code)).\(detail) See the log for details."
    }

    func stopAndClear() {
        Task { await clearNow() }
    }

    func clearNow() async {
        guard toolReady else { return }
        phase = .clearing
        lastError = nil
        await stopHolder()
        appendLog("\n→ clear\n")
        let (code, out) = await runClear()
        appendLog(out)
        activePlace = nil
        phase = .idle
        if code == 0 {
            recentlyCleared = true
            clearedNoteTask?.cancel()
            clearedNoteTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { recentlyCleared = false }
            }
        } else {
            lastError = "Clear failed: " + Self.explain(output: out, code: code, tunnelRunning: tunnelRunning)
                + " If the phone still shows a fake location, toggle Location Services off and on."
            await refreshTunnel()
        }
    }

    /// `simulate-location clear` sends `stopLocationSimulation` fire-and-forget (no reply) and then
    /// exits at once. When the tunnel lives inside that same Python process (the default on recent
    /// pymobiledevice3), the message can be dropped before it reaches the phone — the CLI still
    /// exits 0 and the phone stays on the fake location. So we run the very same CLI command through
    /// its own Python interpreter with `clear()` patched to linger briefly after sending.
    private static let lingeringClearScript = """
    import asyncio, sys
    try:
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation as _LS
        _orig_clear = _LS.clear
        async def _clear(self):
            await _orig_clear(self)
            await asyncio.sleep(2.0)  # let the fire-and-forget stop message reach the phone
            print("stopLocationSimulation sent")
        _LS.clear = _clear
    except Exception as e:
        print("note: couldn't patch clear (" + repr(e) + "); using plain clear", file=sys.stderr)
    sys.argv = ["pymobiledevice3", "developer", "dvt", "simulate-location", "clear"]
    from pymobiledevice3.__main__ import main
    sys.exit(main())
    """

    private func runClear() async -> (Int32, String) {
        if let (exe, preArgs) = Self.interpreter(forScript: toolPath) {
            let (code, out) = await Shell.run(exe, preArgs + ["-c", Self.lingeringClearScript], timeout: 30)
            // Only fall back if Python itself couldn't load pymobiledevice3 this way.
            let broken = out.contains("ModuleNotFoundError") || out.contains("ImportError") || code == 127
            if !broken { return (code, out) }
            appendLog(out + "(falling back to plain clear)\n")
        }
        return await Shell.run(toolPath, ["developer", "dvt", "simulate-location", "clear"], timeout: 30)
    }

    /// The Python interpreter from a console-script's shebang line, e.g. `#!/path/to/python3`
    /// or `#!/usr/bin/env python3`.
    static func interpreter(forScript path: String) -> (String, [String])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
        guard head.hasPrefix("#!"), let line = head.split(separator: "\n").first else { return nil }
        let parts = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let exe = parts.first, FileManager.default.isExecutableFile(atPath: exe),
              parts.joined(separator: " ").contains("python") else { return nil }
        return (exe, Array(parts.dropFirst()))
    }

    // MARK: - Tunnel (optional: `pymobiledevice3 remote tunneld`, runs as root. Recent versions
    //         build their own no-root tunnel per command, so this is only a fallback.)

    func refreshTunnel() async {
        let (code, _) = await Shell.run("/usr/bin/pgrep", ["-f", "remote tunneld"], timeout: 5)
        tunnelRunning = (code == 0)
    }

    static let tunnelLogPath = "/tmp/pymobiledevice3-tunneld.log"

    func startTunnel() {
        guard toolReady else { return }
        Task {
            appendLog("\n→ starting tunneld (admin)\n")
            // `--daemonize` forks properly. A plain `nohup … &` gets killed as soon as the
            // privileged `do shell script` shell exits ("nohup: can't detach from console").
            let cmd = "\(Shell.sh(toolPath)) remote tunneld --daemonize > \(Self.tunnelLogPath) 2>&1"
            let script = "do shell script \(Shell.applescript(cmd)) with administrator privileges"
            let (code, out) = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
            if code != 0 {
                appendLog(out)
                if out.contains("-128") { return }   // user cancelled the password prompt
            }
            // Give it a moment to come up, then re-check a few times.
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await refreshTunnel()
                if tunnelRunning == true { break }
            }
            if tunnelRunning == true {
                appendLog("tunneld running (log: \(Self.tunnelLogPath))\n")
            } else {
                let tail = (try? String(contentsOfFile: Self.tunnelLogPath, encoding: .utf8))?
                    .split(separator: "\n").suffix(5).joined(separator: "\n") ?? ""
                if !tail.isEmpty { appendLog(tail + "\n") }
                let last = tail.split(separator: "\n").last.map(String.init) ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = "tunneld didn't stay running" + (last.isEmpty ? "." : ": \(last)")
                    + " Log: \(Self.tunnelLogPath)"
            }
        }
    }

    func stopTunnel() {
        Task {
            if activePlace != nil || hasHolder { await clearNow() }
            appendLog("\n→ stopping tunneld\n")
            // 1. No password: ask tunneld to shut itself down over its local HTTP API.
            if let url = URL(string: "http://127.0.0.1:49151/shutdown") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 3
                _ = try? await URLSession.shared.data(for: req)
            }
            if await waitForTunnel(running: false, seconds: 3) {
                appendLog("tunneld stopped\n")
                return
            }
            // 2. A daemonized tunneld swallows SIGINT/SIGTERM, so escalate to SIGKILL (it runs
            //    as root, hence the admin prompt). `[t]unneld` stops pkill matching its own shell.
            let cmd = "pkill -TERM -f 'remote [t]unneld'; sleep 2; pkill -KILL -f 'remote [t]unneld'; exit 0"
            let script = "do shell script \(Shell.applescript(cmd)) with administrator privileges"
            let (code, out) = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
            if code != 0 {
                appendLog(out)
                if out.contains("-128") { await refreshTunnel(); return }   // cancelled
            }
            if await waitForTunnel(running: false, seconds: 3) {
                appendLog("tunneld stopped\n")
            } else {
                lastError = "Couldn't stop tunneld. In Terminal run: sudo pkill -KILL -f 'remote tunneld'"
            }
        }
    }

    private func waitForTunnel(running: Bool, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            await refreshTunnel()
            if tunnelRunning == running { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await refreshTunnel()
        return tunnelRunning == running
    }

    // MARK: - Log

    func appendLog(_ text: String) {
        log += text
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }
}
