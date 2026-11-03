import CoreLocation
import Foundation
import NetworkExtension

/// Associated-access-point probe for the navigator. State: 0 idle, 1 pending, 2 ready, 3 unavailable.
/// iOS returns no network without the Access Wi-Fi Information entitlement and When-In-Use location.
final class GnarlyWifiProbe: NSObject, CLLocationManagerDelegate {
    static let shared = GnarlyWifiProbe()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var state: Int32 = 0
    private var bssid = ""
    private var started = false
    private var preciseRequested = false
    private var fetchStarted = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        lock.lock()
        if state == 1 || state == 2 {
            lock.unlock()
            return
        }
        state = 1
        bssid = ""
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.begin()
        }
    }

    func snapshot() -> (state: Int32, bssid: String, awaitingAuthorization: Bool) {
        lock.lock()
        let value = (state, bssid)
        lock.unlock()
        let awaiting = manager.authorizationStatus == .notDetermined
        return (value.0, value.1, awaiting)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard started, !fetchStarted else { return }
        begin()
    }

    private func begin() {
        started = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestPrecise()
        default:
            finish(nil)
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
            DispatchQueue.main.async {
                self?.fetchNetwork()
            }
        }
    }

    private func fetchNetwork() {
        guard !fetchStarted else { return }
        fetchStarted = true
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let bssid = network.flatMap { GnarlyWifiProbe.normalize($0.bssid) }
            self?.finish(bssid)
        }
    }

    private func finish(_ value: String?) {
        lock.lock()
        if state == 1 {
            if let value {
                bssid = value
                state = 2
            } else {
                bssid = ""
                state = 3
            }
        }
        lock.unlock()
    }

    /// Lowercase colon-separated MAC. Accepts the leading-zero form iOS sometimes returns.
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

@_cdecl("GnarlyWifiRequestCurrent")
public func GnarlyWifiRequestCurrent() {
    GnarlyWifiProbe.shared.request()
}

@_cdecl("GnarlyWifiState")
public func GnarlyWifiState() -> Int32 {
    GnarlyWifiProbe.shared.snapshot().state
}

@_cdecl("GnarlyWifiAwaitingAuthorization")
public func GnarlyWifiAwaitingAuthorization() -> Int32 {
    GnarlyWifiProbe.shared.snapshot().awaitingAuthorization ? 1 : 0
}

@_cdecl("GnarlyWifiCopyBssid")
public func GnarlyWifiCopyBssid(_ buffer: UnsafeMutablePointer<CChar>, _ capacity: Int32) -> Int32 {
    let snap = GnarlyWifiProbe.shared.snapshot()
    guard snap.state == 2, capacity > 1 else { return 0 }
    let bytes = Array(snap.bssid.utf8)
    let count = min(bytes.count, Int(capacity) - 1)
    guard count == bytes.count else { return 0 }
    for index in 0..<count {
        buffer[index] = CChar(bitPattern: bytes[index])
    }
    buffer[count] = 0
    return Int32(count)
}
