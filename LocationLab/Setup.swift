import SwiftUI
import AppKit
import Combine

/// First-launch / on-demand setup of Python + pymobiledevice3.
///
/// Installs into an app-private Python environment under Application Support, so it never touches
/// the user's own Python, needs no `sudo`, and the app always knows the exact executable path.
@MainActor
final class SetupModel: ObservableObject {
    static let shared = SetupModel()

    enum State: Equatable {
        case checking
        /// No usable Python; Apple's Command Line Tools provide one.
        case needsCommandLineTools
        /// Python found; pymobiledevice3 missing (or the user asked to (re)install).
        case readyToInstall(python: String)
        case working(String)
        case installed(path: String)
        case failed(String)
    }

    @Published var state: State = .checking
    @Published var output = ""

    static let pypiURL = URL(string: "https://pypi.org/project/pymobiledevice3/")!

    static var envDirectory: URL { AppSupport.directory.appendingPathComponent("python", isDirectory: true) }
    static var managedTool: String { envDirectory.appendingPathComponent("bin/pymobiledevice3").path }
    static var managedPython: String { envDirectory.appendingPathComponent("bin/python").path }
    static var isManagedInstallPresent: Bool { FileManager.default.isExecutableFile(atPath: managedTool) }

    // MARK: Detection

    func check() {
        state = .checking
        Task {
            if let python = await Self.findPython() {
                state = .readyToInstall(python: python)
            } else {
                state = .needsCommandLineTools
            }
        }
    }

    /// Prefer Apple's Python (from the Command Line Tools / Xcode) since it's what we test with and
    /// pymobiledevice3's compiled dependencies ship wheels for it; fall back to Homebrew / python.org.
    static func findPython() async -> String? {
        var candidates: [String] = []
        // /usr/bin/python3 is only a stub that pops up an install dialog unless developer tools exist.
        let (cltCode, _) = await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        if cltCode == 0 { candidates.append("/usr/bin/python3") }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        let frameworks = "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
        candidates.append(frameworks)

        for python in candidates where FileManager.default.isExecutableFile(atPath: python) {
            let (code, out) = await Shell.run(python, ["-c", "import sys, venv; print(sys.version_info >= (3, 9))"], timeout: 30)
            if code == 0, out.contains("True") { return python }
        }
        return nil
    }

    // MARK: Commands (shown to the user before anything runs)

    static func installSteps(python: String) -> [[String]] {
        let dir = envDirectory.path
        return [
            [python, "-m", "venv", dir],
            [managedPython, "-m", "pip", "install", "--upgrade", "pip"],
            [managedPython, "-m", "pip", "install", "--upgrade", "pymobiledevice3"],
        ]
    }

    static var updateSteps: [[String]] {
        [[managedPython, "-m", "pip", "install", "--upgrade", "pymobiledevice3"]]
    }

    static func terminalText(_ steps: [[String]]) -> String {
        steps.map(commandLine).joined(separator: " && \\\n  ")
    }

    /// Shell-quotes only the arguments that need it, so commands stay readable.
    static func commandLine(_ argv: [String]) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@+,")
        return argv.map { arg in
            !arg.isEmpty && arg.unicodeScalars.allSatisfy(safe.contains) ? arg : Shell.sh(arg)
        }.joined(separator: " ")
    }

    // MARK: Actions

    func installCommandLineTools() {
        // Opens Apple's own installer dialog; nothing is downloaded by us.
        Task {
            _ = await Shell.run("/usr/bin/xcode-select", ["--install"], timeout: 15)
            output += "Opened Apple's Command Line Tools installer. When it finishes, click “Check Again”.\n"
        }
    }

    func install(python: String) { run(Self.installSteps(python: python), title: "Installing pymobiledevice3…") }

    func update() { run(Self.updateSteps, title: "Updating pymobiledevice3…") }

    private func run(_ steps: [[String]], title: String) {
        state = .working(title)
        output = ""
        Task {
            for step in steps {
                output += "$ " + Self.commandLine(step) + "\n"
                let code = await Self.stream(step) { text in self.output += text }
                if code != 0 {
                    state = .failed("A step failed (exit \(code)). The output above says why; "
                                    + "check your internet connection and try again, or copy the commands and run them in Terminal.")
                    return
                }
            }
            let tool = Self.managedTool
            guard FileManager.default.isExecutableFile(atPath: tool) else {
                state = .failed("The install finished but \(tool) is missing.")
                return
            }
            let c = LocationController.shared
            c.toolPath = tool
            c.lastError = nil
            await c.refreshToolVersion()
            if let v = c.toolVersion { output += "pymobiledevice3 \(v)\n" }
            output += "\nDone. LocationLab will use \(tool)\n"
            state = .installed(path: tool)
        }
    }

    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.title = "Choose the pymobiledevice3 executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            state = .failed("\(url.path) isn't an executable file.")
            return
        }
        let c = LocationController.shared
        c.toolPath = url.path
        c.lastError = nil
        Task { await c.refreshToolVersion() }
        state = .installed(path: url.path)
    }

    /// Runs a command, streaming combined output to `onOutput` on the main actor.
    private static func stream(_ argv: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            env["PIP_PROGRESS_BAR"] = "off"
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                let text = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { onOutput(text) } }
            }
            p.terminationHandler = { proc in
                let code = proc.terminationStatus
                // Let queued output land first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { cont.resume(returning: code) }
            }
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onOutput("Couldn't run \(argv[0]): \(error.localizedDescription)\n") }
                    cont.resume(returning: -1)
                }
            }
        }
    }
}

// MARK: - View

struct SetupView: View {
    @ObservedObject private var model = SetupModel.shared
    @ObservedObject private var controller = LocationController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up LocationLab").font(.title2.bold())
                    Text("LocationLab uses the free, open-source pymobiledevice3 tool to talk to your iPhone.")
                        .foregroundStyle(.secondary)
                }
            }

            content

            if !model.output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.output) { proxy.scrollTo("end") }
                }
            }

            HStack {
                if case .working = model.state {} else {
                    Button("I Already Have It…") { model.chooseExisting() }
                }
                Spacer()
                Button(isDone ? "Done" : "Not Now") { dismiss() }
                    .keyboardShortcut(isDone ? .defaultAction : .cancelAction)
                    .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { if model.state == .checking { model.check() } }
    }

    private var installHeadline: String {
        if SetupModel.isManagedInstallPresent { return "LocationLab's copy of pymobiledevice3 is installed." }
        if controller.toolReady { return "Optional: install LocationLab's own copy of pymobiledevice3." }
        return "pymobiledevice3 isn't installed yet."
    }

    private var isDone: Bool { if case .installed = model.state { return true } else { return false } }
    private var isWorking: Bool { if case .working = model.state { return true } else { return false } }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking for Python…") }

        case .needsCommandLineTools:
            VStack(alignment: .leading, spacing: 8) {
                Label("Python isn't installed yet.", systemImage: "exclamationmark.circle").font(.headline)
                Text("Apple's Command Line Tools include Python. Installing them opens Apple's own installer; LocationLab doesn't download anything itself.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install Command Line Tools") { model.installCommandLineTools() }
                        .keyboardShortcut(.defaultAction)
                    Button("Check Again") { model.check() }
                }
            }

        case .readyToInstall(let python):
            VStack(alignment: .leading, spacing: 8) {
                Label(installHeadline, systemImage: "shippingbox").font(.headline)
                if controller.toolReady {
                    Text("Currently using \(controller.toolPath)\(controller.toolVersion.map { " (version \($0))" } ?? "").")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("**Install for Me** creates a private Python environment just for LocationLab and installs pymobiledevice3 into it from the Python Package Index ([pypi.org](\(SetupModel.pypiURL.absoluteString))). Your own Python setup isn't changed and no admin password is needed. It takes about a minute.")
                    .fixedSize(horizontal: false, vertical: true)
                CommandBox(text: SetupModel.terminalText(SetupModel.installSteps(python: python)))
                Text("Installs to \(SetupModel.envDirectory.path). To remove it later, delete that folder.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if SetupModel.isManagedInstallPresent {
                        Button("Update") { model.update() }
                            .keyboardShortcut(.defaultAction)
                        Button("Reinstall") { model.install(python: python) }
                    } else {
                        Button("Install for Me") { model.install(python: python) }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Copy Terminal Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SetupModel.terminalText(SetupModel.installSteps(python: python)), forType: .string)
                    }
                }
            }

        case .working(let title):
            HStack { ProgressView().controlSize(.small); Text(title) }

        case .installed(let path):
            VStack(alignment: .leading, spacing: 6) {
                Label("pymobiledevice3 is ready.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let v = controller.toolVersion { Text("Version \(v)").font(.caption).foregroundStyle(.secondary) }
                Text("Connect and unlock your iPhone (Developer Mode on), then pick a place.")
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.check() }
            }
        }
    }
}

/// Monospaced, selectable command text so users can see exactly what will run.
struct CommandBox: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
