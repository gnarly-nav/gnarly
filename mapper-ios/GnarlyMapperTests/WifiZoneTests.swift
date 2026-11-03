import XCTest
@testable import GnarlyMapper

final class WifiZoneTests: XCTestCase {
    func testNormalizesBssid() {
        XCTAssertEqual(WifiBssid.normalize("AA:BB:CC:DD:EE:FF"), "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(WifiBssid.normalize("a:b:c:d:e:f"), "0a:0b:0c:0d:0e:0f")
        XCTAssertNil(WifiBssid.normalize("aa:bb:cc:dd:ee"))
        XCTAssertNil(WifiBssid.normalize("gg:bb:cc:dd:ee:ff"))
    }

    func testDocumentKeepsUniqueAccessPoints() {
        let first = WifiAccessPoint.make(bssid: "AA:BB:CC:DD:EE:FF", ssid: " Hall ")
        let repeatReading = WifiAccessPoint.make(bssid: "aa:bb:cc:dd:ee:ff", ssid: "Other")
        let second = WifiAccessPoint.make(bssid: "11:22:33:44:55:66", ssid: " ")
        let document = WifiZoneDocument.make(zoneId: " floor-2 ", readings: [first, repeatReading, second].compactMap { $0 })
        XCTAssertEqual(document?.zoneId, "floor-2")
        XCTAssertEqual(document?.accessPoints, [
            WifiAccessPoint(bssid: "aa:bb:cc:dd:ee:ff", ssid: "Hall"),
            WifiAccessPoint(bssid: "11:22:33:44:55:66", ssid: nil),
        ])
        XCTAssertNil(WifiZoneDocument.make(zoneId: "floor-2", readings: []))
    }
}
