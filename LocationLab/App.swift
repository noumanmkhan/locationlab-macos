import SwiftUI
import AppKit
import MapKit
import Combine

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
            CommandGroup(replacing: .newItem) {
                Button("New Folder") { UIState.shared.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Address…") {
                    NotificationCenter.default.post(name: .showAddressSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Divider()
                RestoreDefaultsCommand()
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
    case favourites
    case folder(UUID)
    case city(String)
}

extension Notification.Name {
    static let showAddressSearch = Notification.Name("showAddressSearch")
}

/// Window-wide UI state that menu commands and context menus both need (prompts and confirmations).
@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()

    enum FolderPrompt: Equatable {
        case create(moving: [Place])
        case rename(UUID)
    }

    @Published var folderPrompt: FolderPrompt?
    @Published var folderName = ""
    @Published var folderToDelete: FavouriteFolder?
    @Published var cityToDelete: City?
    @Published var confirmRestore = false
    /// Set after a folder is created so the sidebar can select it.
    @Published var selectFolder: UUID?

    func newFolder(moving places: [Place] = []) {
        folderName = ""
        folderPrompt = .create(moving: places)
    }

    func rename(_ folder: FavouriteFolder) {
        folderName = folder.name
        folderPrompt = .rename(folder.id)
    }

    func commitFolderPrompt() {
        let store = LibraryStore.shared
        switch folderPrompt {
        case .create(let places):
            let id = store.createFolder(named: folderName)
            if !places.isEmpty { store.move(places, to: id) }
            selectFolder = id
        case .rename(let id):
            store.renameFolder(id, to: folderName)
        case nil:
            break
        }
        folderPrompt = nil
    }
}

/// Edit › Restore Deleted Places…, enabled only when something was deleted.
struct RestoreDefaultsCommand: View {
    @ObservedObject private var store = LibraryStore.shared
    var body: some View {
        Button("Restore Deleted Places…") { UIState.shared.confirmRestore = true }
            .disabled(store.hiddenDefaultsCount == 0)
    }
}

struct ContentView: View {
    @ObservedObject private var s = LocationController.shared
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var ui = UIState.shared
    @State private var selection: SidebarItem? = LibraryStore.shared.visibleCities.first.map { .city($0.id) } ?? .search
    @State private var showLog = false
    @StateObject private var search = AddressSearch()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                StatusBar()
                if !s.toolReady && !s.needsSetup {
                    SetupBanner()
                }
                if let err = s.lastError {
                    ErrorBanner(text: err) { s.lastError = nil }
                }
                if let err = store.storageError {
                    ErrorBanner(text: err) { store.storageError = nil }
                }
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                LogDrawer(expanded: $showLog)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddressSearch)) { _ in
            selection = .search
        }
        .onChange(of: store.data) { validateSelection() }
        .onChange(of: ui.selectFolder) {
            if let id = ui.selectFolder { selection = .folder(id); ui.selectFolder = nil }
        }
        .sheet(isPresented: $s.needsSetup) { SetupView() }
        .alert(folderPromptTitle, isPresented: folderPromptShown) {
            TextField("Folder name", text: $ui.folderName)
            Button(folderPromptAction) { ui.commitFolderPrompt() }
            Button("Cancel", role: .cancel) { ui.folderPrompt = nil }
        }
        .confirmationDialog(
            "Delete the folder “\(ui.folderToDelete?.name ?? "")”?",
            isPresented: Binding(get: { ui.folderToDelete != nil }, set: { if !$0 { ui.folderToDelete = nil } }),
            presenting: ui.folderToDelete
        ) { folder in
            Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id) }
        } message: { folder in
            let n = store.favourites(in: folder.id).count
            Text(n == 0 ? "The folder is empty." : "Its \(n) favourite\(n == 1 ? "" : "s") will stay in All Favourites.")
        }
        .confirmationDialog(
            "Delete “\(ui.cityToDelete?.name ?? "")” and its places?",
            isPresented: Binding(get: { ui.cityToDelete != nil }, set: { if !$0 { ui.cityToDelete = nil } }),
            presenting: ui.cityToDelete
        ) { city in
            Button("Delete City", role: .destructive) { store.hideCity(city.id) }
        } message: { _ in
            Text("Favourites from this city are kept. You can bring it back with Edit › Restore Deleted Places.")
        }
        .confirmationDialog(
            "Restore all deleted built-in places and cities?",
            isPresented: $ui.confirmRestore
        ) {
            Button("Restore") { store.restoreDefaults() }
        } message: {
            Text("Your favourites and folders aren't changed.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Search") {
                Label("Address Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            }

            Section {
                Label("All Favourites", systemImage: "star")
                    .badge(store.data.favourites.count)
                    .tag(SidebarItem.favourites)
                    .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
                ForEach(store.data.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(store.favourites(in: folder.id).count)
                        .tag(SidebarItem.folder(folder.id))
                        .dropDestination(for: String.self) { items, _ in drop(items, into: folder.id) }
                        .contextMenu {
                            Button("Rename…") { ui.rename(folder) }
                            Button("Delete Folder…", role: .destructive) { ui.folderToDelete = folder }
                        }
                }
                .onMove { store.moveFolders(from: $0, to: $1) }
            } header: {
                Text("Favourites")
            }

            Section("Cities") {
                ForEach(store.visibleCities) { city in
                    Label(city.name, systemImage: city.symbol)
                        .tag(SidebarItem.city(city.id))
                        .contextMenu {
                            Button("Delete City…", role: .destructive) { ui.cityToDelete = city }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { ui.newFolder() } label: { Label("New Folder", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Folder (⇧⌘N)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Places dragged onto "All Favourites" or a folder.
    private func drop(_ items: [String], into folder: UUID?) -> Bool {
        let places = items.compactMap(Place.init(dragPayload:))
        guard !places.isEmpty else { return false }
        if folder == nil {
            // Onto All Favourites: star anything not starred yet; don't pull starred ones out of their folder.
            store.move(places.filter { !store.isFavourite($0) }, to: nil)
        } else {
            store.move(places, to: folder)
        }
        return true
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .search:
            AddressSearchView(search: search)
        case .favourites:
            favouritesList(folder: nil)
        case .folder(let id):
            favouritesList(folder: id)
        case .city(let id):
            if let city = store.visibleCities.first(where: { $0.id == id }) {
                if city.places.isEmpty {
                    ContentUnavailableView("No Places", systemImage: "mappin.slash",
                                           description: Text("All of this city's places were deleted. Edit › Restore Deleted Places brings them back."))
                } else {
                    PlaceList(places: city.places, kind: .city).id(selection)
                }
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    @ViewBuilder private func favouritesList(folder: UUID?) -> some View {
        let places = store.favourites(in: folder)
        if places.isEmpty {
            ContentUnavailableView(
                folder == nil ? "No Favourites Yet" : "Empty Folder",
                systemImage: folder == nil ? "star" : "folder",
                description: Text(folder == nil
                    ? "Click the star next to any place to save it here."
                    : "Drag places onto this folder in the sidebar, or right-click a place and choose Move to Folder.")
            )
        } else {
            PlaceList(places: places, kind: .favourites(folder)).id(selection)
        }
    }

    private var placeholder: some View {
        Text("Pick a city").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keep the selection valid after a folder or city is deleted.
    private func validateSelection() {
        switch selection {
        case .folder(let id) where store.folder(id) == nil:
            selection = .favourites
        case .city(let id) where !store.visibleCities.contains(where: { $0.id == id }):
            selection = store.visibleCities.first.map { .city($0.id) } ?? .favourites
        default:
            break
        }
    }

    // MARK: Folder name alert

    private var folderPromptShown: Binding<Bool> {
        Binding(get: { ui.folderPrompt != nil }, set: { if !$0 { ui.folderPrompt = nil } })
    }
    private var folderPromptTitle: String {
        if case .rename = ui.folderPrompt { return "Rename Folder" }
        return "New Folder"
    }
    private var folderPromptAction: String {
        if case .rename = ui.folderPrompt { return "Rename" }
        return "Create"
    }
}

struct SetupBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
            Text("pymobiledevice3 isn't set up yet, so LocationLab can't reach your iPhone.").font(.callout)
            Spacer()
            Button("Set Up…") {
                SetupModel.shared.check()
                LocationController.shared.needsSetup = true
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
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

/// Where a list of places is shown; decides which actions apply.
enum PlaceListKind: Equatable {
    case city
    case favourites(UUID?)   // nil = All Favourites
    case search
}

nonisolated extension Place {
    private static let dragPrefix = "locationlab-place:"

    /// Plain-text drag payload: a prefix plus the place as JSON, so drops from elsewhere are ignored.
    var dragPayload: String {
        let json = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Self.dragPrefix + json
    }

    init?(dragPayload: String) {
        guard dragPayload.hasPrefix(Self.dragPrefix),
              let place = try? JSONDecoder().decode(Place.self, from: Data(dragPayload.dropFirst(Self.dragPrefix.count).utf8))
        else { return nil }
        self = place
    }

    var mapsURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=\(q)")
    }
}

struct PlaceRow: View {
    let place: Place
    let kind: PlaceListKind
    /// Outside a selectable list (search results): the row handles double-click and its own menu.
    var standalone = false
    @ObservedObject private var s = LocationController.shared
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        let isActive = s.activePlace == place && s.phase == .active
        let isFavourite = store.isFavourite(place)
        let row = HStack {
            Image(systemName: isActive ? "location.fill" : "mappin")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).fontWeight(isActive ? .semibold : .regular)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.toggleFavourite(place) } label: {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .foregroundStyle(isFavourite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavourite ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityLabel(isFavourite ? "Remove from Favourites" : "Add to Favourites")
            if isActive {
                Text("Active").font(.caption).foregroundStyle(.green)
            } else {
                Button("Go") { s.simulate(place) }
                    .disabled(s.busy || !s.toolReady)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())

        if standalone {
            row
                .onTapGesture(count: 2) { if !s.busy && s.toolReady { s.simulate(place) } }
                .contextMenu { PlaceMenu(places: [place], kind: kind) }
                .draggable(place.dragPayload)
        } else {
            row
        }
    }

    private var subtitle: String {
        // In favourites, show which folder a place is in when looking at All Favourites.
        if case .favourites(nil) = kind, let id = store.folderID(of: place), let folder = store.folder(id) {
            return "\(place.area) · \(place.coordText) · \(folder.name)"
        }
        return "\(place.area) · \(place.coordText)"
    }
}

/// Context-menu actions for one or more places.
struct PlaceMenu: View {
    let places: [Place]
    let kind: PlaceListKind
    @ObservedObject private var s = LocationController.shared
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        let ids = Set(places.map(\.id))
        let allFavourites = places.allSatisfy(store.isFavourite)

        if places.count == 1, let place = places.first {
            Button("Go") { s.simulate(place) }
                .disabled(s.busy || !s.toolReady)
            Divider()
        }

        if allFavourites {
            Button("Remove from Favourites") { store.removeFavourites(ids) }
        } else {
            Button("Add to Favourites") { store.move(places.filter { !store.isFavourite($0) }, to: nil) }
        }

        Menu("Move to Folder") {
            let current = Set(places.map { store.isFavourite($0) ? store.folderID(of: $0) : UUID() })
            ForEach(store.data.folders) { folder in
                Button {
                    store.move(places, to: folder.id)
                } label: {
                    if current == [folder.id] { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
            if !store.data.folders.isEmpty { Divider() }
            Button("New Folder…") { UIState.shared.newFolder(moving: places) }
        }

        if case .favourites(let folder?) = kind {
            Button("Remove from “\(store.folder(folder)?.name ?? "Folder")”") { store.move(places, to: nil) }
        }

        if places.count == 1, let place = places.first {
            Divider()
            Button("Copy Coordinates") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(place.coordText, forType: .string)
            }
            Button("Open in Maps") { if let url = place.mapsURL { NSWorkspace.shared.open(url) } }
        }

        if kind == .city {
            Divider()
            Button(places.count == 1 ? "Delete Place" : "Delete \(places.count) Places", role: .destructive) {
                store.hidePlaces(ids)
            }
        }
    }
}

struct PlaceList: View {
    let places: [Place]
    let kind: PlaceListKind
    @State private var selection = Set<Place.ID>()
    @ObservedObject private var s = LocationController.shared
    @ObservedObject private var store = LibraryStore.shared

    private var canReorder: Bool { if case .favourites = kind { return true } else { return false } }

    var body: some View {
        List(selection: $selection) {
            ForEach(places) { place in
                if canReorder {
                    // Reordering uses the list's own drag; drag to folders from a city list or search.
                    PlaceRow(place: place, kind: kind)
                } else {
                    PlaceRow(place: place, kind: kind).draggable(place.dragPayload)
                }
            }
            .onMove(perform: canReorder ? { from, to in
                if case .favourites(let folder) = kind { store.reorderFavourites(in: folder, from: from, to: to) }
            } : nil)
        }
        .contextMenu(forSelectionType: Place.ID.self) { ids in
            PlaceMenu(places: places.filter { ids.contains($0.id) }, kind: kind)
        } primaryAction: { ids in
            // Double-click or Return.
            if ids.count == 1, let place = places.first(where: { ids.contains($0.id) }), !s.busy, s.toolReady {
                s.simulate(place)
            }
        }
        .onDeleteCommand { deleteSelection() }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        switch kind {
        case .city: store.hidePlaces(selection)
        case .favourites: store.removeFavourites(selection)
        case .search: return
        }
        selection.removeAll()
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
                            ForEach(search.results) { PlaceRow(place: $0, kind: .search, standalone: true) }
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
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("pymobiledevice3") {
                TextField("Path", text: $s.toolPath)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Image(systemName: s.toolReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(s.toolReady ? .green : .red)
                    Text(s.toolReady ? "Found" + (s.toolVersion.map { " · version \($0)" } ?? "") : "Not an executable file")
                    Spacer()
                    Button("Auto-detect") { s.autodetect() }
                }
                HStack {
                    Text(SetupModel.isManagedInstallPresent
                         ? "Installed by LocationLab. Update or reinstall it from Setup."
                         : "Don't have it? Setup can install it for you.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Setup…") {
                        openWindow(id: "main")
                        SetupModel.shared.check()
                        s.needsSetup = true
                    }
                }
            }

            Section("Places") {
                HStack {
                    let n = store.hiddenDefaultsCount
                    Text(n == 0 ? "No built-in places or cities are deleted."
                                : "Deleted built-in places and cities: \(n)")
                    Spacer()
                    Button("Restore Deleted Places") { store.restoreDefaults() }
                        .disabled(n == 0)
                }
                HStack {
                    Text("Favourites and folders are saved in Application Support.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppSupport.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppSupport.directory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .padding()
    }
}
