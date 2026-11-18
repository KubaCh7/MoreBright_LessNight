import CoreLocation
import Foundation
import os

/// When the "day" and "night" brightness modes start.
enum ScheduleKind: String, CaseIterable, Identifiable {
    /// Local sunrise and sunset (needs a location, asked once).
    case sun
    /// Fixed times of day.
    case custom
    var id: String { rawValue }
}

enum DayPeriod: String {
    case day, night
}

/// Sunrise and sunset from the NOAA solar position equations (accurate to a few minutes,
/// computed locally, no network).
enum SolarCalculator {
    /// Sunrise and sunset for the calendar day containing `date` in `timeZone`, or nil
    /// during polar day / polar night.
    static func sunTimes(on date: Date, latitude: Double, longitude: Double,
                         timeZone: TimeZone = .current) -> (sunrise: Date, sunset: Date)? {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        guard let dayOfYear = local.ordinality(of: .day, in: .year, for: date) else { return nil }

        let g = 2 * Double.pi / 365 * Double(dayOfYear - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                               - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let lat = latitude * Double.pi / 180
        let zenith = 90.833 * Double.pi / 180 // includes refraction and the sun's radius
        let x = cos(zenith) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        guard abs(x) <= 1 else { return nil }
        let hourAngle = acos(x) * 180 / Double.pi

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnightUTC = utc.date(from: parts) else { return nil }
        let sunriseMinutes = 720 - 4 * (longitude + hourAngle) - eqTime
        let sunsetMinutes = 720 - 4 * (longitude - hourAngle) - eqTime
        return (midnightUTC.addingTimeInterval(sunriseMinutes * 60),
                midnightUTC.addingTimeInterval(sunsetMinutes * 60))
    }
}

/// One-shot location for the sun schedule. Main-thread only. The last fix is cached, so the
/// schedule keeps working offline; it is refreshed at most once a day.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        if defaults.object(forKey: "scheduleLatitude") != nil {
            coordinate = CLLocationCoordinate2D(latitude: defaults.double(forKey: "scheduleLatitude"),
                                                longitude: defaults.double(forKey: "scheduleLongitude"))
        }
    }

    var authorizationDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Asks for permission the first time; afterwards refreshes the fix if it's a day old.
    func refreshIfNeeded(force: Bool = false) {
        let last = defaults.object(forKey: "scheduleLocationDate") as? Date ?? .distantPast
        guard force || coordinate == nil || Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        default:
            lastError = String(localized: "Location access is off. Allow MoreBrightLessNight in System Settings → Privacy & Security → Location Services, or use custom times.")
            onChange?()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            lastError = nil
            manager.requestLocation()
        case .denied, .restricted:
            lastError = String(localized: "Location access is off. Allow MoreBrightLessNight in System Settings → Privacy & Security → Location Services, or use custom times.")
        default:
            break
        }
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        lastError = nil
        defaults.set(location.coordinate.latitude, forKey: "scheduleLatitude")
        defaults.set(location.coordinate.longitude, forKey: "scheduleLongitude")
        defaults.set(Date(), forKey: "scheduleLocationDate")
        overlayLog.info("schedule location updated")
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the cached fix if there is one; only surface the error when there's nothing.
        if coordinate == nil { lastError = error.localizedDescription }
        onChange?()
    }
}
