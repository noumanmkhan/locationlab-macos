import Foundation
import MapKit
import Combine

/// Address / place-name lookup backed by MapKit.
/// Typing drives `MKLocalSearchCompleter` (suggestions); picking a suggestion or pressing Return
/// runs `MKLocalSearch` to get real coordinates, which come back as ordinary `Place`s.
@MainActor
final class AddressSearch: NSObject, ObservableObject {
    @Published var query: String = "" {
        didSet { queryChanged() }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var results: [Place] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?

    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    private func queryChanged() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        message = nil
        if q.isEmpty {
            completer.cancel()
            suggestions = []
            results = []
        } else {
            completer.queryFragment = q
        }
    }

    /// Return key: search the typed text directly.
    func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        run(MKLocalSearch.Request(naturalLanguageQuery: q), label: q)
    }

    /// Resolve a suggestion to coordinates.
    func pick(_ completion: MKLocalSearchCompletion) {
        run(MKLocalSearch.Request(completion: completion), label: completion.title)
    }

    private func run(_ request: MKLocalSearch.Request, label: String) {
        search?.cancel()
        request.resultTypes = [.address, .pointOfInterest]
        let s = MKLocalSearch(request: request)
        search = s
        searching = true
        message = nil
        Task {
            defer { if self.search === s { self.searching = false } }
            do {
                let response = try await s.start()
                guard self.search === s else { return }
                self.results = Self.uniquePlaces(response.mapItems.map(Self.place(from:)))
                self.suggestions = []
                if self.results.isEmpty { self.message = "No matches for “\(label)”." }
            } catch {
                guard self.search === s else { return }
                self.results = []
                self.message = Self.describe(error, label: label)
            }
        }
    }

    private static func place(from item: MKMapItem) -> Place {
        let coord: CLLocationCoordinate2D
        let address: String?
        if #available(macOS 26, *) {
            coord = item.location.coordinate
            address = item.address?.shortAddress ?? item.address?.fullAddress
        } else {
            coord = item.placemark.coordinate
            address = item.placemark.title
        }
        let name = item.name ?? address ?? "Dropped pin"
        var area = (address ?? "").replacingOccurrences(of: "\n", with: ", ")
        if area.isEmpty || area == name { area = "Search result" }
        return Place(name: name, area: area, lat: coord.latitude, lon: coord.longitude)
    }

    private static func uniquePlaces(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        return places.filter { seen.insert($0.id).inserted }
    }

    private static func describe(_ error: Error, label: String) -> String {
        if let e = error as? MKError {
            switch e.code {
            case .placemarkNotFound, .directionsNotFound: return "No matches for “\(label)”."
            case .serverFailure, .loadingThrottled:
                return "Apple Maps search is unavailable right now (\(e.code == .loadingThrottled ? "rate-limited" : "server error")). Try again shortly."
            default: break
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Search needs an internet connection."
        }
        return "Search failed: \(error.localizedDescription)"
    }
}

extension AddressSearch: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Partial queries often "fail" with placemarkNotFound; just show nothing.
        suggestions = []
    }
}
