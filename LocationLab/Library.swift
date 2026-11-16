import Foundation
import Combine
import SwiftUI

// MARK: - Model

/// A user-created folder for favourites.
nonisolated struct FavouriteFolder: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
}

/// A starred place. Each favourite is in at most one folder (`folderID == nil` = not in a folder).
nonisolated struct Favourite: Identifiable, Hashable, Codable, Sendable {
    var place: Place
    var folderID: UUID?
    var id: String { place.id }
}

/// Everything the user can change, saved as one JSON file.
/// Built-in places are not copied here: deleting one only records its ID in `hiddenPlaceIDs`, so
/// new or corrected default places in future versions still show up.
nonisolated struct LibraryData: Codable, Equatable, Sendable {
    var version = 1
    var favourites: [Favourite] = []
    var folders: [FavouriteFolder] = []
    var hiddenPlaceIDs: Set<String> = []
    var hiddenCityIDs: Set<String> = []

    init() {}

    // Tolerant decoding: missing keys fall back to defaults, so older/newer files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        favourites = try c.decodeIfPresent([Favourite].self, forKey: .favourites) ?? []
        folders = try c.decodeIfPresent([FavouriteFolder].self, forKey: .folders) ?? []
        hiddenPlaceIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenPlaceIDs) ?? []
        hiddenCityIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenCityIDs) ?? []
    }
}

// MARK: - Storage location

enum AppSupport {
    /// `~/Library/Application Support/LocationLab`, or `$LOCATIONLAB_SUPPORT_DIR` (used for testing).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["LOCATIONLAB_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocationLab", isDirectory: true)
    }
}

// MARK: - Store

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var data = LibraryData()
    /// Set if the saved file couldn't be read or written.
    @Published var storageError: String?

    private var fileURL: URL { AppSupport.directory.appendingPathComponent("library.json") }

    private init() { load() }

    // MARK: Persistence

    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
        } catch {
            // Keep the unreadable file instead of overwriting it, and start fresh.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent("library.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            storageError = "Your saved favourites couldn't be read, so LocationLab started with an empty list. "
                + "The old file was kept as \(backup.lastPathComponent)."
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: AppSupport.directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            storageError = "Couldn't save favourites: \(error.localizedDescription)"
        }
    }

    private func update(_ change: (inout LibraryData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        data = copy
        save()
    }

    // MARK: Favourites

    func isFavourite(_ place: Place) -> Bool { data.favourites.contains { $0.id == place.id } }

    /// Favourites in a folder, or all of them when `folder` is nil.
    func favourites(in folder: UUID?) -> [Place] {
        data.favourites.filter { folder == nil || $0.folderID == folder }.map(\.place)
    }

    func folderID(of place: Place) -> UUID? { data.favourites.first { $0.id == place.id }?.folderID }

    func toggleFavourite(_ place: Place, into folder: UUID? = nil) {
        update { d in
            if let i = d.favourites.firstIndex(where: { $0.id == place.id }) {
                d.favourites.remove(at: i)
            } else {
                d.favourites.append(Favourite(place: place, folderID: folder))
            }
        }
    }

    func removeFavourites(_ ids: Set<String>) {
        update { d in d.favourites.removeAll { ids.contains($0.id) } }
    }

    /// Move favourites into a folder (`nil` = out of any folder). Places that aren't favourites yet are starred.
    func move(_ places: [Place], to folder: UUID?) {
        update { d in
            for place in places {
                if let i = d.favourites.firstIndex(where: { $0.id == place.id }) {
                    d.favourites[i].folderID = folder
                } else {
                    d.favourites.append(Favourite(place: place, folderID: folder))
                }
            }
        }
    }

    /// Reorder within the list shown for `folder` (nil = All Favourites).
    func reorderFavourites(in folder: UUID?, from source: IndexSet, to destination: Int) {
        update { d in
            // Indices of the visible subset inside the full array.
            let slots = d.favourites.indices.filter { folder == nil || d.favourites[$0].folderID == folder }
            var subset = slots.map { d.favourites[$0] }
            subset.move(fromOffsets: source, toOffset: destination)
            for (slot, fav) in zip(slots, subset) { d.favourites[slot] = fav }
        }
    }

    // MARK: Folders

    func folder(_ id: UUID) -> FavouriteFolder? { data.folders.first { $0.id == id } }

    @discardableResult
    func createFolder(named name: String) -> UUID {
        let folder = FavouriteFolder(id: UUID(), name: Self.clean(name, fallback: "New Folder"))
        update { $0.folders.append(folder) }
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        update { d in
            guard let i = d.folders.firstIndex(where: { $0.id == id }) else { return }
            d.folders[i].name = Self.clean(name, fallback: d.folders[i].name)
        }
    }

    /// Deletes the folder only; its favourites stay in All Favourites.
    func deleteFolder(_ id: UUID) {
        update { d in
            d.folders.removeAll { $0.id == id }
            for i in d.favourites.indices where d.favourites[i].folderID == id { d.favourites[i].folderID = nil }
        }
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        update { $0.folders.move(fromOffsets: source, toOffset: destination) }
    }

    private static func clean(_ name: String, fallback: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    // MARK: Built-in places

    /// Built-in cities with deleted cities and places removed.
    var visibleCities: [City] {
        Catalog.cities
            .filter { !data.hiddenCityIDs.contains($0.id) }
            .map { City(name: $0.name, symbol: $0.symbol, places: $0.places.filter { !data.hiddenPlaceIDs.contains($0.id) }) }
    }

    func isBuiltIn(_ place: Place) -> Bool { Catalog.cities.contains { $0.places.contains(place) } }

    func hidePlaces(_ ids: Set<String>) { update { $0.hiddenPlaceIDs.formUnion(ids) } }
    func hideCity(_ id: String) { update { $0.hiddenCityIDs.insert(id) } }

    var hiddenDefaultsCount: Int { data.hiddenPlaceIDs.count + data.hiddenCityIDs.count }

    /// Brings back every deleted built-in place and city. Favourites and folders are untouched.
    func restoreDefaults() {
        update { d in
            d.hiddenPlaceIDs.removeAll()
            d.hiddenCityIDs.removeAll()
        }
    }
}
