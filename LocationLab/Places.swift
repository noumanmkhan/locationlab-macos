import Foundation

/// Plain data, Codable so lists can later be loaded from / exported to JSON.
nonisolated struct Place: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let area: String
    let lat: Double
    let lon: Double
    var id: String { "\(name)|\(lat)|\(lon)" }

    var coordText: String { String(format: "%.4f, %.4f", lat, lon) }
}

nonisolated struct City: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let symbol: String
    let places: [Place]
    var id: String { name }
}

/// Built-in default list. Kept as plain data so it can later come from a bundled JSON file.
nonisolated enum Catalog {
    static let cities: [City] = [
        City(name: "Toronto / GTA", symbol: "building.2", places: [
            Place(name: "CN Tower", area: "Downtown Toronto", lat: 43.6426, lon: -79.3871),
            Place(name: "Toronto City Hall", area: "Downtown Toronto", lat: 43.6534, lon: -79.3841),
            Place(name: "Yonge-Dundas Square", area: "Downtown Toronto", lat: 43.6561, lon: -79.3802),
            Place(name: "North York Centre", area: "North York", lat: 43.7676, lon: -79.4128),
            Place(name: "Scarborough Town Centre", area: "Scarborough", lat: 43.7756, lon: -79.2578),
            Place(name: "Pearson Airport (YYZ)", area: "Mississauga", lat: 43.6777, lon: -79.6248),
            Place(name: "Square One", area: "Mississauga", lat: 43.5931, lon: -79.6424),
            Place(name: "Downtown Brampton", area: "Brampton", lat: 43.6853, lon: -79.7596),
            Place(name: "Markham Civic Centre", area: "Markham", lat: 43.8561, lon: -79.3370),
            Place(name: "Vaughan Mills", area: "Vaughan", lat: 43.8255, lon: -79.5384),
            Place(name: "Downtown Oakville", area: "Oakville", lat: 43.4473, lon: -79.6668),
        ]),
        City(name: "Vancouver / Metro", symbol: "mountain.2", places: [
            Place(name: "Canada Place", area: "Downtown Vancouver", lat: 49.2888, lon: -123.1111),
            Place(name: "Stanley Park", area: "Vancouver", lat: 49.3043, lon: -123.1443),
            Place(name: "Granville Island", area: "Vancouver", lat: 49.2712, lon: -123.1340),
            Place(name: "UBC", area: "Point Grey", lat: 49.2606, lon: -123.2460),
            Place(name: "Vancouver Airport (YVR)", area: "Richmond", lat: 49.1951, lon: -123.1779),
            Place(name: "Richmond Centre", area: "Richmond", lat: 49.1680, lon: -123.1365),
            Place(name: "Metrotown", area: "Burnaby", lat: 49.2276, lon: -123.0001),
            Place(name: "Surrey Central", area: "Surrey", lat: 49.1897, lon: -122.8490),
            Place(name: "Lonsdale Quay", area: "North Vancouver", lat: 49.3100, lon: -123.0830),
            Place(name: "Coquitlam Centre", area: "Coquitlam", lat: 49.2780, lon: -122.8010),
        ]),
        City(name: "New York / Metro", symbol: "building.columns", places: [
            Place(name: "Times Square", area: "Manhattan", lat: 40.7580, lon: -73.9855),
            Place(name: "Central Park (Bethesda Terrace)", area: "Manhattan", lat: 40.7740, lon: -73.9708),
            Place(name: "Wall Street", area: "Manhattan", lat: 40.7060, lon: -74.0090),
            Place(name: "DUMBO", area: "Brooklyn", lat: 40.7033, lon: -73.9881),
            Place(name: "Flushing", area: "Queens", lat: 40.7590, lon: -73.8303),
            Place(name: "JFK Airport", area: "Queens", lat: 40.6413, lon: -73.7781),
            Place(name: "Yankee Stadium", area: "Bronx", lat: 40.8296, lon: -73.9262),
            Place(name: "St. George Ferry Terminal", area: "Staten Island", lat: 40.6437, lon: -74.0736),
            Place(name: "Exchange Place", area: "Jersey City, NJ", lat: 40.7163, lon: -74.0336),
            Place(name: "Hoboken", area: "Hoboken, NJ", lat: 40.7440, lon: -74.0324),
            Place(name: "Newark Airport (EWR)", area: "Newark, NJ", lat: 40.6895, lon: -74.1745),
        ]),
        City(name: "San Francisco / Bay Area", symbol: "sun.haze", places: [
            Place(name: "Union Square", area: "San Francisco", lat: 37.7880, lon: -122.4075),
            Place(name: "Ferry Building", area: "San Francisco", lat: 37.7955, lon: -122.3937),
            Place(name: "Golden Gate Bridge Vista", area: "San Francisco", lat: 37.8078, lon: -122.4750),
            Place(name: "SFO Airport", area: "San Mateo County", lat: 37.6213, lon: -122.3790),
            Place(name: "Downtown Oakland", area: "Oakland", lat: 37.8044, lon: -122.2712),
            Place(name: "UC Berkeley", area: "Berkeley", lat: 37.8719, lon: -122.2585),
            Place(name: "University Ave", area: "Palo Alto", lat: 37.4446, lon: -122.1630),
            Place(name: "Googleplex", area: "Mountain View", lat: 37.4220, lon: -122.0841),
            Place(name: "Apple Park", area: "Cupertino", lat: 37.3349, lon: -122.0090),
            Place(name: "Downtown San Jose", area: "San Jose", lat: 37.3337, lon: -121.8907),
        ]),
        City(name: "London / Greater London", symbol: "crown", places: [
            Place(name: "Trafalgar Square", area: "Westminster", lat: 51.5080, lon: -0.1281),
            Place(name: "Tower of London", area: "City of London", lat: 51.5081, lon: -0.0759),
            Place(name: "King's Cross", area: "Camden", lat: 51.5308, lon: -0.1238),
            Place(name: "Camden Market", area: "Camden", lat: 51.5415, lon: -0.1460),
            Place(name: "Canary Wharf", area: "Tower Hamlets", lat: 51.5054, lon: -0.0235),
            Place(name: "Westfield Stratford", area: "Newham", lat: 51.5430, lon: -0.0060),
            Place(name: "Wembley Stadium", area: "Brent", lat: 51.5560, lon: -0.2796),
            Place(name: "Wimbledon", area: "Merton", lat: 51.4214, lon: -0.2064),
            Place(name: "East Croydon", area: "Croydon", lat: 51.3762, lon: -0.0982),
            Place(name: "Heathrow Airport", area: "Hillingdon", lat: 51.4700, lon: -0.4543),
        ]),
        City(name: "Dubai / Sharjah", symbol: "sun.max", places: [
            Place(name: "Burj Khalifa / Dubai Mall", area: "Downtown Dubai", lat: 25.1972, lon: 55.2744),
            Place(name: "DIFC", area: "Dubai", lat: 25.2117, lon: 55.2815),
            Place(name: "Business Bay", area: "Dubai", lat: 25.1857, lon: 55.2677),
            Place(name: "Gold Souk", area: "Deira", lat: 25.2697, lon: 55.2962),
            Place(name: "Dubai Airport (DXB)", area: "Garhoud", lat: 25.2532, lon: 55.3657),
            Place(name: "Dubai Marina", area: "Dubai", lat: 25.0805, lon: 55.1403),
            Place(name: "Atlantis, Palm Jumeirah", area: "Palm Jumeirah", lat: 25.1304, lon: 55.1171),
            Place(name: "Mall of the Emirates", area: "Al Barsha", lat: 25.1181, lon: 55.2006),
            Place(name: "Jumeirah Village Circle", area: "JVC", lat: 25.0587, lon: 55.2093),
            Place(name: "Dubai Silicon Oasis", area: "DSO", lat: 25.1210, lon: 55.3780),
            Place(name: "Al Majaz Waterfront", area: "Sharjah", lat: 25.3255, lon: 55.3830),
        ]),
        City(name: "Hyderabad / Secunderabad", symbol: "building", places: [
            Place(name: "Charminar", area: "Old City", lat: 17.3616, lon: 78.4747),
            Place(name: "Golconda Fort", area: "Golconda", lat: 17.3833, lon: 78.4011),
            Place(name: "Hussain Sagar", area: "Central Hyderabad", lat: 17.4239, lon: 78.4738),
            Place(name: "Banjara Hills", area: "Banjara Hills", lat: 17.4138, lon: 78.4398),
            Place(name: "Jubilee Hills", area: "Jubilee Hills", lat: 17.4325, lon: 78.4071),
            Place(name: "Ameerpet", area: "Ameerpet", lat: 17.4375, lon: 78.4483),
            Place(name: "Secunderabad Station", area: "Secunderabad", lat: 17.4337, lon: 78.5016),
            Place(name: "HITEC City (Cyber Towers)", area: "Madhapur", lat: 17.4504, lon: 78.3808),
            Place(name: "Gachibowli", area: "Gachibowli", lat: 17.4401, lon: 78.3489),
            Place(name: "Financial District", area: "Nanakramguda", lat: 17.4140, lon: 78.3430),
            Place(name: "Kukatpally", area: "Kukatpally", lat: 17.4948, lon: 78.3996),
            Place(name: "Rajiv Gandhi Airport (HYD)", area: "Shamshabad", lat: 17.2403, lon: 78.4294),
        ]),
        City(name: "Tokyo / Yokohama", symbol: "tram", places: [
            Place(name: "Shibuya Crossing", area: "Shibuya", lat: 35.6595, lon: 139.7005),
            Place(name: "Shinjuku Station", area: "Shinjuku", lat: 35.6896, lon: 139.7006),
            Place(name: "Tokyo Station", area: "Marunouchi", lat: 35.6812, lon: 139.7671),
            Place(name: "Akihabara", area: "Chiyoda", lat: 35.6984, lon: 139.7731),
            Place(name: "Senso-ji", area: "Asakusa", lat: 35.7148, lon: 139.7967),
            Place(name: "Tokyo Skytree", area: "Sumida", lat: 35.7101, lon: 139.8107),
            Place(name: "Roppongi Hills", area: "Minato", lat: 35.6605, lon: 139.7292),
            Place(name: "Odaiba", area: "Minato", lat: 35.6270, lon: 139.7750),
            Place(name: "Haneda Airport", area: "Ota", lat: 35.5494, lon: 139.7798),
            Place(name: "Minato Mirai", area: "Yokohama", lat: 35.4570, lon: 139.6320),
        ]),
    ]
}
