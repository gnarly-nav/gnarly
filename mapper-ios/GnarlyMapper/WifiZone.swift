import CoreLocation
import Foundation
import NetworkExtension

/// Canonical form of an access-point BSSID. iOS sometimes omits leading zeros.
enum WifiBssid {
    static func normalize(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        octets.reserveCapacity(6)
        for part in parts {
            guard part.count == 1 || part.count == 2, let value = UInt8(part, radix: 16) else { return nil }
            octets.append(String(format: "%02x", value))
        }
        return octets.joined(separator: ":")
    }
}

struct WifiAccessPoint: Codable, Equatable {
    var bssid: String
    var ssid: String?

    static func make(bssid rawBssid: String, ssid rawSsid: String?) -> WifiAccessPoint? {
        guard let bssid = WifiBssid.normalize(rawBssid) else { return nil }
        let trimmed = rawSsid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ssid = trimmed.isEmpty ? nil : String(trimmed.prefix(32))
        return WifiAccessPoint(bssid: bssid, ssid: ssid)
    }
}

struct WifiZoneDocument: Codable, Equatable {
    static let fileName = "wifi-zone.json"

    var schemaVersion: Int = 1
    var zoneId: String
    var accessPoints: [WifiAccessPoint]

    /// One entry per BSSID, at most eight. Empty input writes no file.
    static func make(zoneId: String, readings: [WifiAccessPoint]) -> WifiZoneDocument? {
        let trimmed = zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var points: [WifiAccessPoint] = []
        for reading in readings {
            guard points.count < 8, !points.contains(where: { $0.bssid == reading.bssid }) else { continue }
            points.append(reading)
        }
        guard !points.isEmpty else { return nil }
        return WifiZoneDocument(schemaVersion: 1, zoneId: trimmed, accessPoints: points)
    }
}

/// Reads the associated access point. iOS returns nothing without the Wi-Fi information
/// entitlement, When-In-Use location, and a joined Wi-Fi network.
@MainActor
final class WifiZoneReader: NSObject, CLLocationManagerDelegate {
    static let shared = WifiZoneReader()

    private let manager = CLLocationManager()
    private var waiter: CheckedContinuation<WifiAccessPoint?, Never>?
    private var preciseRequested = false
    private var fetchStarted = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    func prepare() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func current() async -> WifiAccessPoint? {
        await withCheckedContinuation { continuation in
            if waiter != nil {
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.complete(nil)
            }
            resumeFetch()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waiter != nil, !fetchStarted else { return }
        resumeFetch()
    }

    private func resumeFetch() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestPrecise()
        default:
            complete(nil)
        }
    }

    private func requestPrecise() {
        guard manager.accuracyAuthorization != .fullAccuracy else {
            fetchNetwork()
            return
        }
        guard !preciseRequested else { return }
        preciseRequested = true
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WifiZone") { [weak self] _ in
            Task { @MainActor in
                self?.fetchNetwork()
            }
        }
    }

    private func fetchNetwork() {
        guard waiter != nil, !fetchStarted else { return }
        fetchStarted = true
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let point = network.flatMap { WifiAccessPoint.make(bssid: $0.bssid, ssid: $0.ssid) }
            Task { @MainActor in
                self?.fetchStarted = false
                self?.complete(point)
            }
        }
    }

    private func complete(_ point: WifiAccessPoint?) {
        guard let waiter else { return }
        self.waiter = nil
        preciseRequested = false
        fetchStarted = false
        waiter.resume(returning: point)
    }
}

/// Access points heard during one scan. Samples are throttled because iOS reports only the joined network.
@MainActor
final class WifiZoneLog {
    static let shared = WifiZoneLog()

    private var points: [WifiAccessPoint] = []
    private var sampling = false
    private var lastSampleAt: Date?

    func reset() {
        points = []
        lastSampleAt = nil
        WifiZoneReader.shared.prepare()
        sampleSoon(force: true)
    }

    func sampleSoon(force: Bool = false) {
        let due = force || lastSampleAt == nil || Date().timeIntervalSince(lastSampleAt ?? .distantPast) >= 15
        guard due, !sampling, points.count < 8 else { return }
        sampling = true
        Task {
            let reading = await WifiZoneReader.shared.current()
            lastSampleAt = Date()
            if let reading, points.count < 8, !points.contains(where: { $0.bssid == reading.bssid }) {
                points.append(reading)
            }
            sampling = false
        }
    }

    func finishDocument(zoneId: String) async -> WifiZoneDocument? {
        sampleSoon(force: true)
        while sampling {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return WifiZoneDocument.make(zoneId: zoneId, readings: points)
    }
}
