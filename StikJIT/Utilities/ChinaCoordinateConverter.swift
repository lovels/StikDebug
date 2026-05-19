//
//  ChinaCoordinateConverter.swift
//  StikJIT
//
//  Converts coordinates between the GCJ-02 ("Mars") system used by Apple Maps
//  inside mainland China and the WGS-84 system that the device's GPS reports.
//
//  Background: when MapKit renders tiles for mainland China it uses GCJ-02
//  coordinates. Tapping a pin therefore yields a GCJ-02 lat/lon that is
//  shifted ~100-700 m from its true WGS-84 position. Forwarding that pair to
//  `simulate_location` makes the simulated GPS report the GCJ-02 values to
//  apps that expect WGS-84, producing the offset users see in China. We
//  reverse the transform here so the simulated GPS lines up with reality.
//
//  The forward GCJ-02 transform is well documented; the reverse is computed
//  iteratively because it has no closed form. Three or four iterations get
//  us well below GPS noise (~1e-9 deg, sub-millimetre).
//
//  Hong Kong, Macau, and Taiwan use WGS-84 in Apple Maps, so the bounding-box
//  check is intentionally limited to mainland China.
//

import CoreLocation

enum ChinaCoordinateConverter {
    /// Krasovsky 1940 semi-major axis used by GCJ-02.
    private static let a: Double = 6_378_245.0
    /// Squared eccentricity for the same ellipsoid.
    private static let ee: Double = 0.006_693_421_622_965_943

    /// Rough bounding box for mainland China. Matches the constants used in
    /// every public GCJ-02 implementation; excludes HK/Macau/Taiwan, which
    /// already render in WGS-84 inside Apple Maps.
    static func isLikelyMainlandChina(latitude: Double, longitude: Double) -> Bool {
        guard longitude >= 72.004, longitude <= 137.8347 else { return false }
        guard latitude >= 0.8293, latitude <= 55.8271 else { return false }
        return true
    }

    /// Converts a GCJ-02 coordinate (what MapKit hands out inside mainland
    /// China) to WGS-84 (what the device's GPS hardware natively reports).
    /// Coordinates outside mainland China are returned unchanged.
    static func gcj02ToWgs84(
        latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        guard isLikelyMainlandChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }

        // Iterative reverse of the GCJ-02 forward transform. Converges very
        // quickly; four passes are well under one-millimetre accuracy.
        var wgsLat = latitude
        var wgsLon = longitude
        for _ in 0..<4 {
            let (gcjLat, gcjLon) = wgs84ToGcj02(latitude: wgsLat, longitude: wgsLon)
            let deltaLat = latitude - gcjLat
            let deltaLon = longitude - gcjLon
            wgsLat += deltaLat
            wgsLon += deltaLon
            if abs(deltaLat) < 1e-9 && abs(deltaLon) < 1e-9 { break }
        }
        return (wgsLat, wgsLon)
    }

    /// Convenience overload for `CLLocationCoordinate2D`.
    static func gcj02ToWgs84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let converted = gcj02ToWgs84(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        return CLLocationCoordinate2D(latitude: converted.latitude, longitude: converted.longitude)
    }

    // MARK: - Forward transform (used for the iterative reverse)

    private static func wgs84ToGcj02(
        latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        let dLat = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        let dLon = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let adjustedLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        let adjustedLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (latitude + adjustedLat, longitude + adjustedLon)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

// MARK: - User preference

extension ChinaCoordinateConverter {
    /// UserDefaults key for the toggle exposed in Settings.
    static let preferenceKey = "chinaCoordinateCorrection"

    /// Whether the conversion is currently enabled. Defaults to `true` so
    /// mainland-China users get correct positions out of the box; the
    /// bounding-box check makes it a no-op everywhere else.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: preferenceKey) == nil { return true }
        return defaults.bool(forKey: preferenceKey)
    }
}
