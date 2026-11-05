import Foundation

enum GnarlyApiConfig {
    static func url(from raw: String?) throws -> URL {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else {
            throw PackagePublishError("Set GnarlyApiBaseURL in Info.plist to the publish API origin.")
        }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else {
            throw PackagePublishError("The publish API must use https, or http on localhost.")
        }
        return url
    }

    static func liveBaseURL(bundle: Bundle = .main) throws -> URL {
        let raw = bundle.object(forInfoDictionaryKey: "GnarlyApiBaseURL") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try url(from: trimmed.isEmpty ? CognitoOAuth.defaultAPIBase : trimmed)
    }
}

struct PackagePublishError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct PackageUpload: Encodable {
    var name: String
    var zoneId: String
    var contentType: String
    var fileURL: URL

    func descriptor() throws -> [String: Any] {
        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        guard let size, size.intValue > 0 else { throw PackagePublishError("\(name) is missing.") }
        return ["name": name, "size": size.intValue, "contentType": contentType]
    }
}

struct PublishSession: Decodable {
    var publishId: String
    var versionId: String
    var uploads: [SignedUpload]
}

struct SignedUpload: Decodable {
    var name: String
    var zoneId: String
    var path: String
    var url: URL
    var headers: [String: String]
}

struct PublishCommit: Decodable {
    var versionId: String
    var activeVersion: String?
}

struct PublishedFile: Decodable {
    var name: String
    var path: String?
    var url: URL
}

struct PublishedZone: Decodable {
    var zoneId: String
    var name: String?
    var floorId: String?
    var files: [PublishedFile]
}

struct PublishedPackage: Decodable {
    var buildingId: String?
    var versionId: String
    var files: [PublishedFile]
    var zones: [PublishedZone]
}

struct ListedBuilding: Decodable {
    var id: String
    var name: String?
    var status: String?
    var activeVersion: String?
    var latitude: Double?
    var longitude: Double?
    var mapHeadingDegrees: Double?
}

/// Talks to the publish API. Bytes go to short-lived signed S3 URLs; activeVersion moves only after commit.
struct PackagePublishClient {
    var baseURL: URL
    var token: () async throws -> String
    var session: URLSession = .shared

    static func live() throws -> PackagePublishClient {
        PackagePublishClient(baseURL: try GnarlyApiConfig.liveBaseURL(), token: {
            try await CognitoSession.shared.requireIdToken()
        })
    }

    func listBuildings() async throws -> [OwnedBuilding] {
        let payload: BuildingList = try await send("GET", path: "/v1/buildings", body: nil)
        return payload.buildings.map { item in
            let building = Building(
                id: item.id,
                name: item.name?.isEmpty == false ? item.name! : item.id,
                activeVersion: item.activeVersion,
                status: RecordStatus(rawValue: item.status ?? "") ?? .draft,
                createdAt: nil,
                updatedAt: nil,
                latitude: item.latitude,
                longitude: item.longitude,
                mapHeadingDegrees: item.mapHeadingDegrees
            )
            return OwnedBuilding(building, id: item.id)
        }
    }

    /// Creates the building when it is new. An existing id is left unchanged and is not an error.
    func ensureBuilding(id: String, name: String, latitude: Double?, longitude: Double?, heading: Double?) async throws {
        var body: [String: Any] = ["id": id, "name": name]
        if let latitude { body["latitude"] = latitude }
        if let longitude { body["longitude"] = longitude }
        if let heading { body["mapHeadingDegrees"] = heading }
        let _: CreateBuildingResponse = try await post("/v1/buildings", body: body)
    }

    func package(buildingId: String, versionId: String?) async throws -> PublishedPackage {
        var path = "/v1/buildings/\(pathComponent(buildingId))/package"
        if let versionId, !versionId.isEmpty {
            path += "?version=\(pathComponent(versionId))"
        }
        return try await send("GET", path: path, body: nil)
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PackagePublishError("Download failed (HTTP \(status)).")
        }
        return data
    }

    func savePlacement(buildingId: String, latitude: Double?, longitude: Double?, heading: Double) async throws {
        let data = try await perform("GET", path: "/v1/records", body: nil)
        let recordPath = "buildings/\(buildingId)"
        guard let text = String(data: data, encoding: .utf8),
              let rawBefore = Self.rawRecordData(in: text, path: recordPath),
              let beforeObject = try JSONSerialization.jsonObject(with: Data(rawBefore.utf8)) as? [String: Any] else {
            throw PackagePublishError("That building record was not found.")
        }
        var after = beforeObject
        if let latitude { after["latitude"] = latitude } else { after.removeValue(forKey: "latitude") }
        if let longitude { after["longitude"] = longitude } else { after.removeValue(forKey: "longitude") }
        after["mapHeadingDegrees"] = heading
        let afterData = try JSONSerialization.data(withJSONObject: after, options: [.sortedKeys])
        guard let afterText = String(data: afterData, encoding: .utf8) else {
            throw PackagePublishError("The building placement could not be encoded.")
        }
        let body = #"{"path":\#(jsonLiteral(recordPath)),"before":\#(rawBefore),"after":\#(afterText)}"#
        _ = try await perform("PUT", path: "/v1/records", rawBody: Data(body.utf8))
    }

    /// Uploads `building-layout.json` onto the published version and moves its pointer, the same way the website saves a layout.
    func saveLayout(buildingId: String, versionId: String, data: Data) async throws {
        let detail = try await sendJSON(
            "GET",
            path: "/v1/buildings/\(pathComponent(buildingId))/versions/\(pathComponent(versionId))",
            body: nil
        )
        let version = detail["version"] as? [String: Any] ?? [:]
        let expectedPath = jsonString(version["buildingLayoutPath"])
        let expectedMarker = jsonString(version["webBuildingLayoutRevision"])
        let path = expectedPath.isEmpty ? "buildings/\(buildingId)/\(versionId)/building-layout.json" : expectedPath
        let signed = try await sendJSON("POST", path: "/v1/uploads", body: [
            "path": path,
            "contentType": "application/json",
            "size": data.count,
        ])
        guard let urlString = signed["url"] as? String, let url = URL(string: urlString) else {
            throw PackagePublishError("The publish API did not return an upload URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 170
        if let headers = signed["headers"] as? [String: Any] {
            for (field, value) in headers {
                if let text = value as? String { request.setValue(text, forHTTPHeaderField: field) }
            }
        }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PackagePublishError("Upload of building-layout.json failed (HTTP \(status)).")
        }
        _ = try await sendJSON("POST", path: "/v1/buildings/\(pathComponent(buildingId))/pointers", body: [
            "versionId": versionId,
            "kind": "layout",
            "path": path,
            "marker": UUID().uuidString.lowercased(),
            "expectedPath": expectedPath,
            "expectedMarker": expectedMarker,
        ])
    }

    func startZonePublish(buildingId: String, versionId: String, zone: [String: Any], files: [PackageUpload]) async throws -> PublishSession {
        let descriptors = try files.filter { $0.zoneId.isEmpty }.map { try $0.descriptor() }
        let zoneFiles = try files.filter { !$0.zoneId.isEmpty }.map { try $0.descriptor() }
        var zoneBody = zone
        zoneBody["files"] = zoneFiles
        return try await post(
            "/v1/buildings/\(pathComponent(buildingId))/publishes",
            body: ["versionId": versionId, "zones": [zoneBody], "files": descriptors]
        )
    }

    func startFilePublish(buildingId: String, versionId: String, files: [PackageUpload]) async throws -> PublishSession {
        let descriptors = try files.map { try $0.descriptor() }
        return try await post(
            "/v1/buildings/\(pathComponent(buildingId))/publishes",
            body: ["versionId": versionId, "files": descriptors]
        )
    }

    func upload(_ uploads: [SignedUpload], files: [PackageUpload]) async throws {
        for upload in uploads {
            guard let file = files.first(where: { $0.name == upload.name && ($0.zoneId.isEmpty ? upload.zoneId.isEmpty : $0.zoneId == upload.zoneId) }) else {
                throw PackagePublishError("The API requested \(upload.name), which is not in this package.")
            }
            var request = URLRequest(url: upload.url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 170
            for (field, value) in upload.headers { request.setValue(value, forHTTPHeaderField: field) }
            let (_, response) = try await session.upload(for: request, fromFile: file.fileURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw PackagePublishError("Upload of \(upload.name) failed (HTTP \(status)). The active map was not changed.")
            }
        }
    }

    func commit(buildingId: String, publishId: String) async throws -> PublishCommit {
        try await send("POST", path: "/v1/buildings/\(pathComponent(buildingId))/publishes/\(pathComponent(publishId))/commit", body: [:])
    }

    /// Previous display layout, if the active package has one. A missing layout is not an error.
    func downloadActiveLayout(buildingId: String) async throws -> Data? {
        let package: PublishedPackage
        do { package = try await package(buildingId: buildingId, versionId: nil) }
        catch let error as PackagePublishError {
            if error.message.contains("no active") || error.message.contains("not published") || error.message.contains("missing") { return nil }
            throw error
        }
        guard let file = package.files.first(where: { $0.name == "building-layout.json" }) else { return nil }
        return try? await download(file.url)
    }

    private func post<Response: Decodable>(_ path: String, body: [String: Any]) async throws -> Response {
        try await send("POST", path: path, body: body)
    }

    private func send<Response: Decodable>(_ method: String, path: String, body: [String: Any]?) async throws -> Response {
        let data = try await perform(method, path: path, body: body)
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw PackagePublishError("The publish API returned an unexpected response.") }
    }

    private func sendJSON(_ method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let data = try await perform(method, path: path, body: body)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func perform(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        let raw = body == nil ? nil : try JSONSerialization.data(withJSONObject: body!)
        return try await perform(method, path: path, rawBody: raw)
    }

    private func perform(_ method: String, path: String, rawBody: Data?) async throws -> Data {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: root + "/" + suffix) else {
            throw PackagePublishError("The publish API URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 170
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let rawBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let message = (try? JSONDecoder().decode(ApiEnvelope.self, from: data))?.error.message
            throw PackagePublishError(message ?? "Publish API failed (HTTP \(status)).")
        }
        return data
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func jsonString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return ""
    }

    /// Matches JSON.stringify for the ids we send. Slashes stay literal, the way the API writes them.
    static func jsonLiteral(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": encoded += "\\\\"
            case "\"": encoded += "\\\""
            case "\n": encoded += "\\n"
            case "\r": encoded += "\\r"
            case "\t": encoded += "\\t"
            default:
                if scalar.value < 0x20 { encoded += String(format: "\\u%04x", scalar.value) }
                else { encoded.unicodeScalars.append(scalar) }
            }
        }
        encoded += "\""
        return encoded
    }

    /// The API compares `before` with its own JSON, so the record is copied as returned.
    static func rawRecordData(in json: String, path: String) -> String? {
        let needle = "\"path\":\(jsonLiteral(path))"
        guard let found = json.range(of: needle) else { return nil }
        guard let dataKey = json.range(of: "\"data\":", range: found.upperBound..<json.endIndex) else { return nil }
        return jsonValue(in: json, at: dataKey.upperBound)
    }

    private static func jsonValue(in text: String, at start: String.Index) -> String? {
        var index = start
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        let first = text[index]
        if first != "{" && first != "[" {
            var end = index
            while end < text.endIndex, !",}]".contains(text[end]) { end = text.index(after: end) }
            return String(text[index..<end]).trimmingCharacters(in: .whitespaces)
        }
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = index
        while cursor < text.endIndex {
            let character = text[cursor]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 { return String(text[index...cursor]) }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

struct LayoutWire: Encodable {
    var schemaVersion: Int
    var zones: [BuildingLayoutDocument.ZoneEntry]
    var floors: [BuildingLayoutDocument.FloorName]?
    var notes: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(zones, forKey: .zones)
        try container.encodeIfPresent(floors, forKey: .floors)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, zones, floors, notes }
}

private struct ApiEnvelope: Decodable {
    struct Body: Decodable { var message: String }
    var error: Body
}

private struct BuildingList: Decodable {
    var buildings: [ListedBuilding]
}

private struct CreateBuildingResponse: Decodable {
    var id: String
    var created: Bool?
}
