import SwiftUI
import AppKit
import MapKit

@main
struct LocationLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Writing to a holder's stdin after it exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("LocationLab", id: "main") {
            ContentView()
                .frame(minWidth: 780, minHeight: 540)
        }
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find Address…") {
                    NotificationCenter.default.post(name: .showAddressSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting always restores the phone's real location.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = LocationController.shared
        guard s.activePlace != nil || s.hasHolder || s.phase == .setting else { return .terminateNow }
        Task { @MainActor in
            await s.clearNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Main window

enum SidebarItem: Hashable {
    case search
    case city(String)
}

extension Notification.Name {
    static let showAddressSearch = Notification.Name("showAddressSearch")
}

struct ContentView: View {
    @ObservedObject private var s = LocationController.shared
    @State private var selection: SidebarItem? = Catalog.cities.first.map { .city($0.id) }
    @State private var showLog = false
    @StateObject private var search = AddressSearch()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Search") {
                    Label("Address search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                }
                Section("Cities") {
                    ForEach(Catalog.cities) { city in
                        Label(city.name, systemImage: city.symbol).tag(SidebarItem.city(city.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                StatusBar()
                if let err = s.lastError {
                    ErrorBanner(text: err) { s.lastError = nil }
                }
                Divider()
                Group {
                    if selection == .search {
                        AddressSearchView(search: search)
                    } else if case .city(let id) = selection, let city = Catalog.cities.first(where: { $0.id == id }) {
                        PlaceList(places: city.places)
                    } else {
                        Text("Pick a city").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Divider()
                LogDrawer(expanded: $showLog)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddressSearch)) { _ in
            selection = .search
        }
    }
}

struct StatusBar: View {
    @ObservedObject private var s = LocationController.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TunnelControl()
            Button(role: .destructive) {
                s.stopAndClear()
            } label: {
                Label("Stop & Clear", systemImage: "stop.circle.fill")
            }
            .controlSize(.large)
            .disabled(s.phase == .clearing || !s.toolReady)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop simulating and run simulate-location clear (⌘.)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch s.phase {
        case .active: return "location.fill"
        case .setting, .clearing: return "hourglass"
        case .idle: return "location.slash"
        }
    }
    private var color: Color {
        switch s.phase {
        case .active: return .green
        case .setting, .clearing: return .orange
        case .idle: return .secondary
        }
    }
    private var title: String {
        switch s.phase {
        case .active: return s.activePlace?.name ?? "Simulating"
        case .setting: return "Setting location…"
        case .clearing: return "Clearing…"
        case .idle: return "Real location"
        }
    }
    private var subtitle: String {
        switch s.phase {
        case .active:
            if let p = s.activePlace { return "\(p.area) · \(p.coordText)" }
            return ""
        case .idle:
            return s.recentlyCleared
                ? "Cleared. The iPhone can take 10–20 seconds to get its real GPS fix back."
                : "Not simulating. Pick a place to send to the iPhone."
        default: return " "
        }
    }
}

/// tunneld is optional: recent pymobiledevice3 builds its own no-root tunnel per command.
/// When it's off this is just a small "…" menu; when it's running it shows a green "tunneld" pill
/// so you know a root process is up and can stop it.
struct TunnelControl: View {
    @ObservedObject private var s = LocationController.shared

    var body: some View {
        if s.tunnelRunning == true {
            Menu {
                Button("Stop tunneld (admin)…") { s.stopTunnel() }
                Button("Refresh status") { Task { await s.refreshTunnel() } }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("tunneld")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help("tunneld is running as root. It's optional; stop it if you don't need it.")
        } else {
            Menu {
                Section("Advanced: tunneld (optional)") {
                    Button("Start tunneld (admin)…") { s.startTunnel() }
                        .disabled(!s.toolReady)
                    Button("Refresh status") { Task { await s.refreshTunnel() } }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Tunnel options")
            .help("Advanced. pymobiledevice3 makes its own tunnel for each command, so tunneld is only needed if commands can't reach the phone.")
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }
}

struct PlaceRow: View {
    let place: Place
    @ObservedObject private var s = LocationController.shared

    var body: some View {
        let isActive = s.activePlace == place && s.phase == .active
        HStack {
            Image(systemName: isActive ? "location.fill" : "mappin")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).fontWeight(isActive ? .semibold : .regular)
                Text("\(place.area) · \(place.coordText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("Active").font(.caption).foregroundStyle(.green)
            } else {
                Button("Go") { s.simulate(place) }
                    .disabled(s.busy || !s.toolReady)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !s.busy && s.toolReady { s.simulate(place) }
        }
        .contextMenu {
            Button("Go") { s.simulate(place) }
            Button("Copy coordinates") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(place.coordText, forType: .string)
            }
            Button("Open in Maps") {
                if let url = URL(string: "http://maps.apple.com/?ll=\(place.lat),\(place.lon)&q=\(place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

struct PlaceList: View {
    let places: [Place]

    var body: some View {
        List(places) { place in
            PlaceRow(place: place)
        }
    }
}

struct AddressSearchView: View {
    @ObservedObject var search: AddressSearch
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Enter a place name or street address", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { search.submit() }
                if search.searching {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if search.query.isEmpty && search.results.isEmpty {
                VStack(spacing: 6) {
                    Text("Search Apple Maps for any address or place.")
                    Text("e.g. “1 Infinite Loop, Cupertino” or “Eiffel Tower”. Press Return to search, or pick a suggestion.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let msg = search.message {
                        Text(msg).foregroundStyle(.secondary)
                    }
                    if !search.results.isEmpty {
                        Section("Results") {
                            ForEach(search.results) { PlaceRow(place: $0) }
                        }
                    }
                    if !search.suggestions.isEmpty {
                        Section("Suggestions") {
                            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { _, c in
                                Button { search.pick(c) } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.title)
                                            if !c.subtitle.isEmpty {
                                                Text(c.subtitle).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Look up coordinates")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { fieldFocused = true }
    }
}

struct LogDrawer: View {
    @Binding var expanded: Bool
    @ObservedObject private var s = LocationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("Log", systemImage: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Spacer()
                if expanded {
                    Button("Clear log") { s.log = "" }.buttonStyle(.borderless).font(.caption)
                }
            }
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(s.log.isEmpty ? "No output yet." : s.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(height: 140)
                    .onChange(of: s.log) { proxy.scrollTo("bottom") }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var s = LocationController.shared

    var body: some View {
        Form {
            Section {
                TextField("pymobiledevice3 path", text: $s.toolPath)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Image(systemName: s.toolReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(s.toolReady ? .green : .red)
                    Text(s.toolReady ? "Found" : "Not an executable file")
                    Spacer()
                    Button("Auto-detect") { s.autodetect() }
                }
            } footer: {
                Text("In Terminal, `which pymobiledevice3` prints the path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
