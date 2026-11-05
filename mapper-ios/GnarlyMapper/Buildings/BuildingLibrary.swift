import Foundation
import MapKit
import UIKit

@MainActor
final class BuildingLibrary: ObservableObject {
    @Published private(set) var buildings: [OwnedBuilding] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func refresh(ownerUid: String? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            buildings = try await PackagePublishClient.live().listBuildings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replace(_ building: OwnedBuilding) {
        if let index = buildings.firstIndex(where: { $0.id == building.id }) {
            buildings[index] = building
        } else {
            buildings.insert(building, at: 0)
        }
    }

    func saveAlignment(building: OwnedBuilding, layout: BuildingLayoutDocument) async throws {
        let api = try PackagePublishClient.live()
        try await api.savePlacement(
            buildingId: building.id,
            latitude: building.latitude,
            longitude: building.longitude,
            heading: building.mapHeadingDegrees
        )
        if let versionId = building.activeVersion, !versionId.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(LayoutWire(
                schemaVersion: layout.schemaVersion,
                zones: layout.zones,
                floors: layout.floors,
                notes: layout.notes
            ))
            try await api.saveLayout(buildingId: building.id, versionId: versionId, data: data)
        }
        replace(building)
    }

    func createBuilding(name: String, latitude: Double?, longitude: Double?, heading: Double, ownerUid: String) async throws -> OwnedBuilding {
        let existing = Set(buildings.map(\.id))
        let id = ZoneIdentifier.make(from: name, existing: existing)
        let building = Building(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            activeVersion: nil,
            status: .draft,
            createdAt: nil,
            updatedAt: nil,
            ownerUid: ownerUid,
            latitude: latitude,
            longitude: longitude,
            mapHeadingDegrees: heading
        )
        try await PackagePublishClient.live().ensureBuilding(
            id: id,
            name: building.name,
            latitude: latitude,
            longitude: longitude,
            heading: heading
        )
        let owned = OwnedBuilding(building, id: id)
        buildings.insert(owned, at: 0)
        return owned
    }

    func loadMap(for building: OwnedBuilding) async throws -> BuildingMap {
        let api = try PackagePublishClient.live()
        guard let versionId = building.activeVersion, !versionId.isEmpty else {
            return BuildingMap(building: building, versionId: nil, layout: BuildingLayoutDocument(), zones: [])
        }
        let package = try await api.package(buildingId: building.id, versionId: versionId)
        var layout = BuildingLayoutDocument()
        if let layoutFile = package.files.first(where: { $0.name == "building-layout.json" }),
           let data = try? await api.download(layoutFile.url),
           let decoded = try? JSONDecoder().decode(BuildingLayoutDocument.self, from: data) {
            layout = decoded
        }
        var zones: [BuildingZone] = []
        for zone in package.zones {
            let zoneId = zone.zoneId
            let floorId = zone.floorId ?? "ground"
            if layout.entry(for: zoneId) == nil {
                let level = inferredLevel(floorId)
                let siblings = layout.zones.filter { $0.floor == level }
                let siblingBounds = siblings.isEmpty ? nil : FloorBounds(
                    minX: Float(siblings.map(\.x).min() ?? 0),
                    maxX: Float(siblings.map(\.x).max() ?? 0),
                    minZ: Float(siblings.map(\.z).min() ?? 0),
                    maxZ: Float(siblings.map(\.z).max() ?? 0)
                )
                layout.upsert(.beside(levelBounds: siblingBounds, zoneId: zoneId, level: level))
            }
            let featuresFile = zone.files.first { $0.name == "scan-features.json" }
            let features = try await loadFeatures(file: featuresFile, api: api)
            let surfaces = features.map(BakeSurface.from) ?? []
            let colors = try await loadColors(files: zone.files, api: api)
            let ground = BuildingMesh.ground(of: surfaces)
            let placement = layout.entry(for: zoneId) ?? .beside(levelBounds: nil, zoneId: zoneId, level: inferredLevel(floorId))
            zones.append(BuildingZone(
                record: ZoneRecord(
                    id: zoneId,
                    name: zone.name?.isEmpty == false ? zone.name! : zoneId,
                    floorId: floorId,
                    scanFeaturesPath: featuresFile?.path,
                    surfaceColorsPath: zone.files.first { $0.name == "surface-colors.json" }?.path,
                    surfaceColorAtlasPath: zone.files.first { $0.name == "surface-colors.jpg" }?.path
                ),
                placement: placement,
                surfaces: surfaces,
                floorPolygons: [:],
                colors: colors.document,
                atlas: colors.atlas,
                ground: ground,
                localBounds: BuildingMesh.bounds(of: surfaces),
                loadIssue: features == nil && featuresFile != nil ? "This zone has no drawable scan yet." : nil
            ))
        }
        return BuildingMap(building: building, versionId: versionId, layout: layout, zones: zones)
    }

    func satelliteImage(for building: OwnedBuilding, bounds: FloorBounds?) async -> UIImage? {
        guard let latitude = building.latitude, let longitude = building.longitude else { return nil }
        let meters = Double(max(bounds?.width ?? 40, bounds?.depth ?? 40) + 30)
        let snapshot = MKMapSnapshotter(options: {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), latitudinalMeters: meters, longitudinalMeters: meters)
            options.mapType = .satellite
            options.size = CGSize(width: 1024, height: 1024)
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            return options
        }())
        return try? await snapshot.start().image
    }

    private func loadFeatures(file: PublishedFile?, api: PackagePublishClient) async throws -> ScanFeatures? {
        guard let file else { return nil }
        return try JSONDecoder().decode(ScanFeatures.self, from: try await api.download(file.url))
    }

    private func loadColors(files: [PublishedFile], api: PackagePublishClient) async throws -> (document: SurfaceColorDocument?, atlas: UIImage?) {
        guard let json = files.first(where: { $0.name == "surface-colors.json" }),
              let atlasFile = files.first(where: { $0.name == "surface-colors.jpg" }) else { return (nil, nil) }
        let document = try JSONDecoder().decode(SurfaceColorDocument.self, from: try await api.download(json.url))
        let atlas = UIImage(data: try await api.download(atlasFile.url))
        return (document, atlas)
    }
}

func inferredLevel(_ floorId: String) -> Int {
    let lower = floorId.lowercased()
    if lower.contains("ground") || lower.contains("lobby") { return 0 }
    if lower.contains("basement") {
        return -(Int(lower.filter(\.isNumber)) ?? 1)
    }
    if let number = Int(lower.filter(\.isNumber)), number != 0 || lower.contains("0") {
        return number
    }
    return 0
}
