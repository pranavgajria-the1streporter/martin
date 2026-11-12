import Foundation

/// The weather where you are, so Martin can dress for it. Off until you switch it on in Settings and type a city.
/// Uses Open-Meteo, which needs no account or key. The only thing sent is the city name, then its coordinates.
@MainActor
final class Weather {
    struct Now {
        /// clear, cloudy, fog, rain, snow or storm
        let kind: String
        let temp: Double
        let day: Bool
        let city: String
    }

    private(set) var now: Now?
    private var fetchedAt: Date?
    private var failedAt: Date?
    private var problem: String?
    private var busy = false
    private let defaults = UserDefaults.standard

    var isOn: Bool { defaults.bool(forKey: "weather.on") }
    private var city: String { (defaults.string(forKey: "weather.city") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// One line for Martin's menu, such as "Malmö: 6°, rain".
    var menuLine: String? {
        guard isOn else { return nil }
        if city.isEmpty { return "Weather: type a city in Settings" }
        if let problem { return problem }
        guard let now, now.city == city else { return "Weather: checking…" }
        let name = defaults.string(forKey: "weather.name") ?? city
        return "\(name): \(Int(now.temp.rounded()))°, \(now.kind)"
    }

    /// Checks every 30 minutes, straight away when the city changes, and waits 10 minutes after a failure.
    func refreshIfStale() {
        guard isOn, !city.isEmpty, !busy else { return }
        let cityChanged = now?.city != city && defaults.string(forKey: "weather.resolvedFor") != city
        if !cityChanged {
            if let at = fetchedAt, now?.city == city, Date().timeIntervalSince(at) < 30 * 60 { return }
            if let at = failedAt, Date().timeIntervalSince(at) < 10 * 60 { return }
        }
        busy = true
        let wanted = city
        Task {
            await load(wanted)
            busy = false
        }
    }

    private func load(_ wanted: String) async {
        do {
            let (lat, lon) = try await place(wanted)
            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            url.queryItems = [
                .init(name: "latitude", value: String(lat)),
                .init(name: "longitude", value: String(lon)),
                .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            ]
            let json = try await fetch(url.url!)
            guard let current = json["current"] as? [String: Any],
                  let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue,
                  let code = (current["weather_code"] as? NSNumber)?.intValue else { throw Failure.unreadable }
            let day = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
            now = Now(kind: Self.kind(code), temp: temp, day: day, city: wanted)
            fetchedAt = Date()
            failedAt = nil
            problem = nil
            Log.write("weather: \(wanted) \(Int(temp.rounded()))° \(Self.kind(code))")
        } catch Failure.noSuchCity {
            problem = "Weather: couldn't find \u{201C}\(wanted)\u{201D}"
            failedAt = Date()
            Log.write("weather: no city called \(wanted)")
        } catch {
            problem = nil
            failedAt = Date()
            Log.write("weather: failed (\(error.localizedDescription))")
        }
    }

    /// Turns a city name into coordinates once, and remembers them.
    private func place(_ wanted: String) async throws -> (Double, Double) {
        if defaults.string(forKey: "weather.resolvedFor") == wanted,
           let lat = defaults.object(forKey: "weather.lat") as? Double,
           let lon = defaults.object(forKey: "weather.lon") as? Double {
            return (lat, lon)
        }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: wanted), .init(name: "count", value: "1")]
        let json = try await fetch(url.url!)
        guard let first = (json["results"] as? [[String: Any]])?.first,
              let lat = (first["latitude"] as? NSNumber)?.doubleValue,
              let lon = (first["longitude"] as? NSNumber)?.doubleValue else { throw Failure.noSuchCity }
        defaults.set(wanted, forKey: "weather.resolvedFor")
        defaults.set(lat, forKey: "weather.lat")
        defaults.set(lon, forKey: "weather.lon")
        defaults.set(first["name"] as? String ?? wanted, forKey: "weather.name")
        return (lat, lon)
    }

    private func fetch(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        return json
    }

    /// WMO weather codes, folded into the six kinds Martin dresses for.
    private static func kind(_ code: Int) -> String {
        switch code {
        case 0, 1: return "clear"
        case 2, 3: return "cloudy"
        case 45, 48: return "fog"
        case 51...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "storm"
        default: return "cloudy"
        }
    }

    private enum Failure: Error { case noSuchCity, unreadable }
}
