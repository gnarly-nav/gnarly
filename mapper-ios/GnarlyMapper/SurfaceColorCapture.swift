import ARKit
import CoreImage
import Foundation
import ImageIO
import RoomPlan
import UniformTypeIdentifiers
import simd

// MARK: - Keyframes recorded while scanning

/// A camera photo saved during scanning, with the pose and lens data needed to project it onto RoomPlan surfaces.
struct ColorKeyframe: Sendable {
    let imageURL: URL
    let width: Int
    let height: Int
    /// Pinhole intrinsics scaled to the stored image (pixels).
    let focal: SIMD2<Float>
    let principal: SIMD2<Float>
    /// ARKit camera-to-world transform (sensor orientation, matching the stored image).
    /// This is the initial capture transform; anchorID tracks drift corrections.
    let cameraTransform: simd_float4x4
    /// Anchor UUID tracking this frame's pose; updated by ARKit on loop closure.
    let anchorID: UUID?
    /// LiDAR depth in meters, row-major Float32, aligned with the image at lower resolution.
    let depthURL: URL?
    let depthWidth: Int
    let depthHeight: Int
    /// LiDAR depth confidence map (0=low, 1=medium, 2=high), row-major UInt8, same size as depth.
    let depthConfidenceURL: URL?
    /// Exposure metadata for normalization across frames.
    let exposureDuration: Float
    let exposureOffset: Float
    /// Laplacian variance sharpness score on downsampled luma; higher is sharper.
    let sharpness: Float
}

/// Saves sharp, well-spaced camera frames while RoomPlan scans so walls, floors, doors, and furniture
/// can be colored from real photos after the final room is built.
final class SurfaceColorRecorder {
    // Large floors need more evenly spaced camera coverage for color baking. This affects only
    // optional surface-color capture, not RoomPlan's separate scene-size limit.
    static let maxKeyframes = 960
    private static let storedWidth: CGFloat = 1920  // Increased from 1280 for better quality

    private let queue = DispatchQueue(label: "com.gnarly.mapper.surface-color-keyframes", qos: .utility)
    private let context = CIContext()
    private let lock = NSLock()
    private var frames: [ColorKeyframe] = []
    private var generation = 0
    private var directory = SurfaceColorRecorder.makeDirectory()
    private var anchors: [UUID: ARAnchor] = [:]  // Track pose corrections

    // Main-thread state.
    private var lastKeyframePose: simd_float4x4?
    private var lastKeyframeTime: TimeInterval = 0
    private var previousPose: simd_float4x4?
    private var pending = 0

    var keyframes: [ColorKeyframe] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var count: Int { keyframes.count }
    
    /// Retrieve updated anchor transforms after loop closure, keyed by anchor ID.
    func getAnchorTransforms(_ session: ARSession) -> [UUID: simd_float4x4] {
        lock.lock()
        defer { lock.unlock() }
        var transforms: [UUID: simd_float4x4] = [:]
        for (id, _) in anchors {
            if let anchor = session.anchors.first(where: { $0.identifier == id }) {
                transforms[id] = anchor.transform
            }
        }
        return transforms
    }

    /// Pose and lens for each saved photo, without the JPEG. Used to estimate splat coverage while scanning.
    var coverageCameras: [CoverageCamera] {
        keyframes.map {
            CoverageCamera(
                transform: $0.cameraTransform,
                focal: $0.focal,
                principal: $0.principal,
                width: Float($0.width),
                height: Float($0.height)
            )
        }
    }

    /// Drops all photos. ARKit coordinates change between scans, so old photos would project to the wrong place.
    func reset() {
        let old = directory
        lock.lock()
        frames = []
        generation += 1
        anchors.removeAll()
        lock.unlock()
        directory = Self.makeDirectory()
        lastKeyframePose = nil
        previousPose = nil
        lastKeyframeTime = 0
        queue.async { try? FileManager.default.removeItem(at: old) }
    }

    /// Call on the main thread with the session's current frame, a few times per second while scanning.
    func consider(_ frame: ARFrame, session: ARSession) {
        let camera = frame.camera
        let pose = camera.transform
        defer { previousPose = pose }
        guard case .normal = camera.trackingState else { return }
        // Turning quickly blurs the photo; wait for the camera to settle.
        if let previousPose, Self.angle(previousPose, pose) > 0.12 { return }
        guard pending == 0 else { return }

        lock.lock()
        let index = frames.count
        let currentGeneration = generation
        lock.unlock()
        guard index < Self.maxKeyframes else { return }
        if let last = lastKeyframePose {
            let moved = simd_distance(last.columns.3, pose.columns.3)
            let vertical = abs(pose.columns.3.y - last.columns.3.y)
            // Prefer a floor-to-ceiling sweep: a small vertical move or tilt is enough to keep another photo.
            guard frame.timestamp - lastKeyframeTime >= 0.28,
                  moved >= 0.22 || vertical >= 0.10 || Self.angle(last, pose) >= 0.16 else { return }
        }

        lastKeyframePose = pose
        lastKeyframeTime = frame.timestamp
        pending += 1
        
        // Create an anchor to track pose corrections from loop closure
        let anchor = ARAnchor(transform: pose)
        session.add(anchor: anchor)
        lock.lock()
        anchors[anchor.identifier] = anchor
        lock.unlock()
        
        let image = frame.capturedImage
        let depth = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap
        let depthConfidence = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.confidenceMap
        let resolution = camera.imageResolution
        let intrinsics = camera.intrinsics
        let exposureDuration = Float(camera.exposureDuration)
        let exposureOffset = camera.exposureOffset
        let directory = self.directory
        queue.async { [weak self] in
            guard let self else { return }
            let keyframe = self.encode(
                image: image, depth: depth, depthConfidence: depthConfidence,
                resolution: resolution, intrinsics: intrinsics,
                pose: pose, anchorID: anchor.identifier, 
                exposureDuration: exposureDuration, exposureOffset: exposureOffset,
                directory: directory, index: index)
            self.lock.lock()
            if let keyframe, currentGeneration == self.generation { self.frames.append(keyframe) }
            self.lock.unlock()
            DispatchQueue.main.async { self.pending -= 1 }
        }
    }

    private func encode(
        image: CVPixelBuffer,
        depth: CVPixelBuffer?,
        depthConfidence: CVPixelBuffer?,
        resolution: CGSize,
        intrinsics: simd_float3x3,
        pose: simd_float4x4,
        anchorID: UUID,
        exposureDuration: Float,
        exposureOffset: Float,
        directory: URL,
        index: Int
    ) -> ColorKeyframe? {
        let scale = min(1, Self.storedWidth / resolution.width)
        let width = Int((resolution.width * scale).rounded(.down))
        let height = Int((resolution.height * scale).rounded(.down))
        let scaled = CIImage(cvPixelBuffer: image)
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Compute sharpness score before encoding
        let sharpness = Self.computeSharpness(image: image)
        
        // Use HEIC for better quality at the same size
        let imageURL = directory.appendingPathComponent(String(format: "frame-%04d.heic", index))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let heicData = context.heifRepresentation(of: scaled, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
            return nil
        }
        do {
            try heicData.write(to: imageURL)
        } catch {
            return nil
        }

        var depthURL: URL?
        var depthWidth = 0
        var depthHeight = 0
        if let depth, let data = Self.depthData(depth, width: &depthWidth, height: &depthHeight) {
            let url = directory.appendingPathComponent(String(format: "frame-%04d.depth", index))
            if (try? data.write(to: url)) != nil { depthURL = url }
        }
        
        var depthConfidenceURL: URL?
        if let depthConfidence, let data = Self.confidenceData(depthConfidence) {
            let url = directory.appendingPathComponent(String(format: "frame-%04d.conf", index))
            if (try? data.write(to: url)) != nil { depthConfidenceURL = url }
        }

        let s = Float(scale)
        return ColorKeyframe(
            imageURL: imageURL,
            width: width,
            height: height,
            focal: SIMD2<Float>(intrinsics[0][0] * s, intrinsics[1][1] * s),
            principal: SIMD2<Float>(intrinsics[2][0] * s, intrinsics[2][1] * s),
            cameraTransform: pose,
            anchorID: anchorID,
            depthURL: depthURL,
            depthWidth: depthURL == nil ? 0 : depthWidth,
            depthHeight: depthURL == nil ? 0 : depthHeight,
            depthConfidenceURL: depthConfidenceURL,
            exposureDuration: exposureDuration,
            exposureOffset: exposureOffset,
            sharpness: sharpness
        )
    }

    private static func depthData(_ buffer: CVPixelBuffer, width: inout Int, height: inout Int) -> Data? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: width * height * 4)
        for row in 0 ..< height {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return data
    }
    
    private static func confidenceData(_ buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: width * height)
        for row in 0 ..< height {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return data
    }
    
    /// Laplacian variance sharpness score on downsampled luma; higher is sharper.
    private static func computeSharpness(image: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width > 2, height > 2 else { return 0 }
        
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return 0 }
        
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        let pixelFormat = CVPixelBufferGetPixelFormatType(image)
        
        // Sample center region at reduced resolution for speed
        let sampleWidth = min(width / 4, 160)
        let sampleHeight = min(height / 4, 120)
        let startX = (width - sampleWidth * 4) / 2
        let startY = (height - sampleHeight * 4) / 2
        
        var laplacianSum: Float = 0
        var count = 0
        
        for sy in 1..<(sampleHeight - 1) {
            let y = startY + sy * 4
            for sx in 1..<(sampleWidth - 1) {
                let x = startX + sx * 4
                
                // Sample luma at (x, y) and neighbors
                func luma(dx: Int, dy: Int) -> Float {
                    let row = y + dy
                    let col = x + dx
                    let offset = row * rowBytes + col * 4  // Assuming BGRA/RGBA format
                    let pixel = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                    // Y = 0.299*R + 0.587*G + 0.114*B (ITU-R BT.601)
                    return Float(pixel[2]) * 0.299 + Float(pixel[1]) * 0.587 + Float(pixel[0]) * 0.114
                }
                
                let center = luma(dx: 0, dy: 0)
                let top = luma(dx: 0, dy: -1)
                let bottom = luma(dx: 0, dy: 1)
                let left = luma(dx: -1, dy: 0)
                let right = luma(dx: 1, dy: 0)
                
                // Laplacian: center * 4 - (top + bottom + left + right)
                let lap = abs(center * 4 - (top + bottom + left + right))
                laplacianSum += lap * lap
                count += 1
            }
        }
        
        return count > 0 ? laplacianSum / Float(count) : 0
    }

    private static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-color-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let forwardA = simd_normalize(-SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let forwardB = simd_normalize(-SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        return acos(max(-1, min(1, simd_dot(forwardA, forwardB))))
    }
}

// MARK: - Surfaces to color

/// A RoomPlan surface or object, copied out of `CapturedRoom` so baking can run off the main actor.
struct BakeSurface: Sendable {
    enum Kind: String, Sendable {
        case wall, door, window, opening, floor, object, stairs
    }

    let identifier: String
    let kind: Kind
    let transform: simd_float4x4
    let dimensions: SIMD3<Float>
    let parentIdentifier: String?
    /// Open doors and openings are holes you can see through.
    let isPassable: Bool

    static func all(
        in room: CapturedRoom,
        recoveredStairs: [StairVolume] = [],
        recoveredFloors: [FloorSlab] = []
    ) -> [BakeSurface] {
        func surface(_ item: CapturedRoom.Surface, _ kind: Kind) -> BakeSurface {
            var passable = kind == .opening
            if case .door(let isOpen) = item.category, isOpen { passable = true }
            return BakeSurface(
                identifier: item.identifier.uuidString,
                kind: kind,
                transform: item.transform,
                dimensions: item.dimensions,
                parentIdentifier: item.parentIdentifier?.uuidString,
                isPassable: passable
            )
        }
        var result = room.walls.map { surface($0, .wall) }
        result += room.doors.map { surface($0, .door) }
        result += room.windows.map { surface($0, .window) }
        result += room.openings.map { surface($0, .opening) }
        result += room.floors.map { surface($0, .floor) }
        result += room.objects.map { object in
            BakeSurface(
                identifier: object.identifier.uuidString,
                kind: object.category == .stairs ? .stairs : .object,
                transform: object.transform,
                dimensions: object.dimensions,
                parentIdentifier: object.parentIdentifier?.uuidString,
                isPassable: false
            )
        }
        let present = Set(result.map(\.identifier))
        result += recoveredFloors.filter { !present.contains($0.identifier) }.map(\.surface)
        result += recoveredStairs.filter { !present.contains($0.identifier) }.map { stair in
            BakeSurface(
                identifier: stair.identifier,
                kind: .stairs,
                transform: stair.transform,
                dimensions: stair.dimensions,
                parentIdentifier: nil,
                isPassable: false
            )
        }
        return result
    }

    static func from(_ features: ScanFeatures) -> [BakeSurface] {
        func surface(_ item: ScanFeatureSurface, _ kind: Kind) -> BakeSurface? {
            guard let transform = scanTransform(item.transformColumnMajor), item.dimensions.count == 3 else { return nil }
            return BakeSurface(
                identifier: item.identifier,
                kind: kind,
                transform: transform,
                dimensions: SIMD3(item.dimensions[0], item.dimensions[1], item.dimensions[2]),
                parentIdentifier: item.parentIdentifier,
                isPassable: kind == .opening || item.category == "door-open"
            )
        }
        var result = features.walls.compactMap { surface($0, .wall) }
        result += features.doors.compactMap { surface($0, .door) }
        result += features.windows.compactMap { surface($0, .window) }
        result += features.openings.compactMap { surface($0, .opening) }
        result += features.floors.compactMap { surface($0, .floor) }
        result += features.objects.compactMap { item -> BakeSurface? in
            guard let transform = scanTransform(item.transformColumnMajor), item.dimensions.count == 3 else { return nil }
            return BakeSurface(
                identifier: item.identifier,
                kind: item.category == "stairs" ? .stairs : .object,
                transform: transform,
                dimensions: SIMD3(item.dimensions[0], item.dimensions[1], item.dimensions[2]),
                parentIdentifier: item.parentIdentifier,
                isPassable: false
            )
        }
        return result
    }
}

// MARK: - Output format (surface-colors.json)

struct SurfaceColorDocument: Codable {
    struct Surface: Codable {
        let identifier: String
        let kind: String
        let faces: [Face]
    }

    /// Face names follow three.js BoxGeometry order in the feature's local frame: px, nx, py, pz, nz.
    /// Planar surfaces (walls, doors, windows, floors) only have pz and nz.
    /// Stairs use `tread-<index>` (local +Y, U=+x V=-z) and `riser-<index>` (local +Z, U=+x V=+y). The flight rises toward local -Z.
    /// Inside `rect`, u runs along the face's U axis and the top row is v = 1:
    ///   pz: U=+x V=+y   nz: U=-x V=+y   px: U=-z V=+y   nx: U=+z V=+y   py: U=+x V=-z
    struct Face: Codable {
        let face: String
        /// Average sRGB color, 0...1.
        let color: [Float]
        /// Fraction of texels seen in at least one photo.
        let coverage: Float
        /// Atlas pixel rect [x, y, width, height] from the top-left, or nil when coverage was too low for a texture.
        let rect: [Int]?
    }

    let schemaVersion: Int
    let zoneId: String
    let coordinateSystem: String
    let capturedAt: String
    let atlas: String
    let atlasWidth: Int
    let atlasHeight: Int
    let texelMeters: Float
    let keyframeCount: Int
    let usedLidarDepth: Bool
    let surfaces: [Surface]
    let notes: String
}

struct SurfaceColorBakeResult: Sendable {
    static let jsonFileName = "surface-colors.json"
    static let atlasFileName = "surface-colors.jpg"

    let json: Data
    let atlas: Data
    let summary: String
}

// MARK: - Baking

/// Projects the recorded photos onto every visible face of the final RoomPlan model, rejecting views that are
/// blocked (LiDAR depth, or the room geometry when depth is unavailable), and selects the best view per texel.
enum SurfaceColorBaker {
    static let maxTexels = 4_000_000  // Increased from 3M for finer detail
    static let minTexelMeters: Float = 0.010  // Reduced from 1.5cm to 1.0cm for sharper textures
    static let maxFaceTexels = 1536  // Increased from 1024 for large walls
    static let maxDistance: Float = 7
    static let atlasPadding = 4

    static func bake(
        surfaces: [BakeSurface],
        keyframes: [ColorKeyframe],
        anchorTransforms: [UUID: simd_float4x4],
        zoneID: String,
        capturedAt: String,
        progress: @escaping @Sendable (Double) -> Void
    ) -> SurfaceColorBakeResult? {
        guard !keyframes.isEmpty else { return nil }
        let (faces, texelMeters) = makeFaces(surfaces)
        guard let last = faces.last else { return nil }
        let texelCount = last.offset + last.columns * last.rows
        
        // Changed from weighted average to best-view selection
        // Store (color, weight, frame index) for each texel to pick the best view
        var bestViews = [(color: SIMD3<Float>, weight: Float, frameIndex: Int)](
            repeating: (SIMD3<Float>.zero, 0, -1), 
            count: texelCount
        )
        
        let occluders = makeOccluders(surfaces)
        let toLinear = (0 ..< 256).map { srgbToLinear(Float($0) / 255) }
        var usedDepth = false
        
        // Try to create Metal projector for GPU acceleration
        let metalProjector = MetalSurfaceProjector.create()
        if metalProjector != nil {
            print("[SurfaceColorBaker] Using Metal GPU acceleration")
        } else {
            print("[SurfaceColorBaker] Using CPU fallback (Metal unavailable)")
        }

        for (index, keyframe) in keyframes.enumerated() {
            autoreleasepool {
                guard let frame = FrameData(keyframe, anchorTransforms: anchorTransforms) else { return }
                if frame.depth != nil { usedDepth = true }
                
                bestViews.withUnsafeMutableBufferPointer { buffer in
                    let target = buffer
                    
                    // Try Metal path first, fall back to CPU if it fails
                    var usedMetal = false
                    if let projector = metalProjector {
                        usedMetal = projector.project(
                            faces: faces,
                            frameData: frame,
                            frameIndex: index,
                            occluders: occluders,
                            into: target
                        )
                    }
                    
                    // CPU fallback
                    if !usedMetal {
                        DispatchQueue.concurrentPerform(iterations: faces.count) { faceIndex in
                            projectBestView(
                                face: faces[faceIndex], 
                                frame: frame, 
                                frameIndex: index,
                                occluders: occluders, 
                                toLinear: toLinear, 
                                into: target
                            )
                        }
                    }
                }
            }
            progress(Double(index + 1) / Double(keyframes.count) * 0.85)
        }
        
        // Compute exposure normalization gains from overlapping views
        progress(0.87)
        let exposureGains = computeExposureGains(keyframes: keyframes, bestViews: bestViews, faces: faces)
        
        // Apply exposure normalization to best views
        progress(0.90)
        applyExposureNormalization(bestViews: &bestViews, gains: exposureGains)
        
        // Apply seam leveling between adjacent faces
        progress(0.92)
        let seamLeveled = applySeamLeveling(faces: faces, bestViews: bestViews, surfaces: surfaces)

        let finished = finish(faces: faces, bestViews: seamLeveled)
        progress(0.95)
        guard let atlas = packAtlas(finished) else { return nil }
        progress(1)

        var bySurface = [Int: [SurfaceColorDocument.Face]]()
        var coloredFaces = 0
        var seenTexels = 0
        for item in finished {
            guard let color = item.averageColor else { continue }
            coloredFaces += 1
            seenTexels += item.seenTexels
            bySurface[item.face.surfaceIndex, default: []].append(SurfaceColorDocument.Face(
                face: item.face.name,
                color: [color.x, color.y, color.z].map { linearToSRGB($0) },
                coverage: item.coverage,
                rect: atlas.rects[item.face.offset]
            ))
        }
        let documentSurfaces = bySurface.keys.sorted().map { index in
            SurfaceColorDocument.Surface(
                identifier: surfaces[index].identifier,
                kind: surfaces[index].kind.rawValue,
                faces: bySurface[index] ?? []
            )
        }

        let document = SurfaceColorDocument(
            schemaVersion: 1,
            zoneId: zoneID,
            coordinateSystem: "arkit-world-meters",
            capturedAt: capturedAt,
            atlas: SurfaceColorBakeResult.atlasFileName,
            atlasWidth: atlas.width,
            atlasHeight: atlas.height,
            texelMeters: texelMeters,
            keyframeCount: keyframes.count,
            usedLidarDepth: usedDepth,
            surfaces: documentSurfaces,
            notes: "Real colors projected from scan photos onto RoomPlan surfaces. Identifiers match scan-features.json."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(document) else { return nil }
        let percent = texelCount > 0 ? Int((Float(seenTexels) / Float(texelCount) * 100).rounded()) : 0
        let summary = "Colored \(coloredFaces) of \(faces.count) faces from \(keyframes.count) photos (\(percent)% seen\(usedDepth ? ", LiDAR-checked" : ""))."
        return SurfaceColorBakeResult(json: json, atlas: atlas.jpeg, summary: summary)
    }

    // MARK: Faces

    struct Face {
        let surfaceIndex: Int
        /// Occluder this face belongs to. A step is not blocked by its own tread and riser.
        let occluderID: Int
        let name: String
        let center: SIMD3<Float>
        let uAxis: SIMD3<Float>
        let vAxis: SIMD3<Float>
        let normal: SIMD3<Float>
        let width: Float
        let height: Float
        var columns = 0
        var rows = 0
        var offset = 0

        var radius: Float { 0.5 * (width * width + height * height).squareRoot() }

        func point(column: Int, row: Int) -> SIMD3<Float> {
            let u = (Float(column) + 0.5) / Float(columns) - 0.5
            let v = 0.5 - (Float(row) + 0.5) / Float(rows)
            return center + uAxis * (u * width) + vAxis * (v * height)
        }
    }

    private static func makeFaces(_ surfaces: [BakeSurface]) -> ([Face], Float) {
        var faces = [Face]()
        for (index, surface) in surfaces.enumerated() where surface.kind != .opening {
            let t = surface.transform
            let x = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
            let y = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
            let z = simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let c = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let d = simd_abs(surface.dimensions)
            func add(_ name: String, _ offset: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, _ n: SIMD3<Float>, _ w: Float, _ h: Float, _ occluder: Int) {
                guard w > 0.02, h > 0.02 else { return }
                faces.append(Face(surfaceIndex: index, occluderID: occluder, name: name, center: c + offset, uAxis: u, vAxis: v, normal: n, width: w, height: h))
            }
            if surface.kind == .stairs {
                for face in StairSteps.faces(dimensions: d) {
                    let offset = x * face.center.x + y * face.center.y + z * face.center.z
                    let u = x * face.axisU.x + y * face.axisU.y + z * face.axisU.z
                    let v = x * face.axisV.x + y * face.axisV.y + z * face.axisV.z
                    add(face.name, offset, u, v, simd_normalize(simd_cross(u, v)), face.width, face.height, stairOccluderID(surface: index, step: face.stepIndex))
                }
            } else if surface.kind == .object {
                add("px", x * (d.x / 2), -z, y, x, d.z, d.y, index)
                add("nx", -x * (d.x / 2), z, y, -x, d.z, d.y, index)
                add("py", y * (d.y / 2), x, -z, y, d.x, d.z, index)
                add("pz", z * (d.z / 2), x, y, z, d.x, d.y, index)
                add("nz", -z * (d.z / 2), -x, y, -z, d.x, d.y, index)
            } else {
                add("pz", .zero, x, y, z, d.x, d.y, index)
                add("nz", .zero, -x, y, -z, d.x, d.y, index)
            }
        }

        let area = faces.reduce(Float(0)) { $0 + $1.width * $1.height }
        let texel = max(minTexelMeters, (area / Float(maxTexels)).squareRoot())
        var offset = 0
        for index in faces.indices {
            faces[index].columns = min(maxFaceTexels, max(2, Int((faces[index].width / texel).rounded(.up))))
            faces[index].rows = min(maxFaceTexels, max(2, Int((faces[index].height / texel).rounded(.up))))
            faces[index].offset = offset
            offset += faces[index].columns * faces[index].rows
        }
        return (faces, texel)
    }

    /// Step occluders must not share ids with surface indexes, which start at 0.
    private static func stairOccluderID(surface: Int, step: Int) -> Int {
        1_000_000 + surface * 64 + step
    }

    // MARK: Occlusion without LiDAR depth

    struct Occluder {
        let occluderID: Int
        let center: SIMD3<Float>
        let x: SIMD3<Float>
        let y: SIMD3<Float>
        let z: SIMD3<Float>
        let half: SIMD3<Float>
        let radius: Float
        let planar: Bool
        /// Child openings, open doors, and windows in wall-local coordinates: minX, minY, maxX, maxY.
        let holes: [SIMD4<Float>]

        func hits(origin: SIMD3<Float>, direction: SIMD3<Float>, maxT: Float) -> Bool {
            let offset = origin - center
            let o = SIMD3<Float>(simd_dot(offset, x), simd_dot(offset, y), simd_dot(offset, z))
            let d = SIMD3<Float>(simd_dot(direction, x), simd_dot(direction, y), simd_dot(direction, z))
            if planar {
                guard abs(d.z) > 1e-5 else { return false }
                let t = -o.z / d.z
                guard t > 0, t < maxT else { return false }
                let hx = o.x + d.x * t
                let hy = o.y + d.y * t
                guard abs(hx) <= half.x, abs(hy) <= half.y else { return false }
                return !holes.contains { hx > $0.x && hx < $0.z && hy > $0.y && hy < $0.w }
            }
            var near: Float = 0
            var far = maxT
            for axis in 0 ..< 3 {
                if abs(d[axis]) < 1e-6 {
                    if abs(o[axis]) > half[axis] { return false }
                    continue
                }
                var t1 = (-half[axis] - o[axis]) / d[axis]
                var t2 = (half[axis] - o[axis]) / d[axis]
                if t1 > t2 { swap(&t1, &t2) }
                near = max(near, t1)
                far = min(far, t2)
                if near > far { return false }
            }
            return near < maxT
        }
    }

    private static func makeOccluders(_ surfaces: [BakeSurface]) -> [Occluder] {
        var holes = [String: [SIMD4<Float>]]()
        let wallsByID = Dictionary(
            surfaces.filter { $0.kind == .wall }.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first })
        for surface in surfaces where surface.isPassable || surface.kind == .window {
            guard let parentID = surface.parentIdentifier, let wall = wallsByID[parentID] else { continue }
            let toWall = wall.transform.inverse * surface.transform
            let center = SIMD2<Float>(toWall.columns.3.x, toWall.columns.3.y)
            let half = simd_abs(surface.dimensions) / 2
            holes[parentID, default: []].append(SIMD4<Float>(center.x - half.x, center.y - half.y, center.x + half.x, center.y + half.y))
        }

        return surfaces.enumerated().flatMap { index, surface -> [Occluder] in
            guard !surface.isPassable, surface.kind != .window else { return [] }
            let t = surface.transform
            let x = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
            let y = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
            let z = simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let c = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            if surface.kind == .stairs {
                return StairSteps.boxes(dimensions: simd_abs(surface.dimensions)).enumerated().map { stepIndex, step in
                    let half = step.size / 2
                    return Occluder(
                        occluderID: stairOccluderID(surface: index, step: stepIndex),
                        center: c + x * step.center.x + y * step.center.y + z * step.center.z,
                        x: x, y: y, z: z,
                        half: half,
                        radius: simd_length(half),
                        planar: false,
                        holes: []
                    )
                }
            }
            let half = simd_abs(surface.dimensions) / 2
            return [Occluder(
                occluderID: index,
                center: c,
                x: x, y: y, z: z,
                half: half,
                radius: simd_length(half),
                planar: surface.kind != .object,
                holes: holes[surface.identifier] ?? []
            )]
        }
    }

    // MARK: Projection

    struct FrameData {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let depth: [Float]?
        let depthConfidence: [UInt8]?
        let depthWidth: Int
        let depthHeight: Int
        let cameraPosition: SIMD3<Float>
        let worldToCamera: simd_float4x4
        let focal: SIMD2<Float>
        let principal: SIMD2<Float>
        let exposureDuration: Float
        let exposureOffset: Float
        let sharpness: Float

        init?(_ keyframe: ColorKeyframe, anchorTransforms: [UUID: simd_float4x4]) {
            guard let source = CGImageSourceCreateWithURL(keyframe.imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.pixels = pixels
            self.width = width
            self.height = height

            var depth: [Float]?
            if let url = keyframe.depthURL, let data = try? Data(contentsOf: url),
               data.count == keyframe.depthWidth * keyframe.depthHeight * 4, keyframe.depthWidth > 0 {
                depth = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            self.depth = depth
            
            var depthConfidence: [UInt8]?
            if let url = keyframe.depthConfidenceURL, let data = try? Data(contentsOf: url),
               data.count == keyframe.depthWidth * keyframe.depthHeight {
                depthConfidence = Array(data)
            }
            self.depthConfidence = depthConfidence
            
            depthWidth = keyframe.depthWidth
            depthHeight = keyframe.depthHeight

            // Use updated anchor transform if available (tracks loop closure corrections)
            let t = keyframe.anchorID.flatMap { anchorTransforms[$0] } ?? keyframe.cameraTransform
            cameraPosition = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            worldToCamera = t.inverse
            // Intrinsics are for the stored image size, which may differ by rounding from the recorded size.
            let sx = Float(width) / Float(max(1, keyframe.width))
            let sy = Float(height) / Float(max(1, keyframe.height))
            focal = SIMD2<Float>(keyframe.focal.x * sx, keyframe.focal.y * sy)
            principal = SIMD2<Float>(keyframe.principal.x * sx, keyframe.principal.y * sy)
            exposureDuration = keyframe.exposureDuration
            exposureOffset = keyframe.exposureOffset
            sharpness = keyframe.sharpness
        }
    }

    private static func projectBestView(
        face: Face,
        frame: FrameData,
        frameIndex: Int,
        occluders: [Occluder],
        toLinear: [Float],
        into bestViews: UnsafeMutableBufferPointer<(color: SIMD3<Float>, weight: Float, frameIndex: Int)>
    ) {
        let camera = frame.cameraPosition
        let toCamera = camera - face.center
        guard simd_dot(toCamera, face.normal) > 0.03 else { return }
        guard simd_length(toCamera) - face.radius < maxDistance else { return }
        guard projectedBoundsOverlap(face: face, frame: frame) else { return }

        let blockers = frame.depth == nil
            ? occluders.filter { occluder in
                occluder.occluderID != face.occluderID &&
                    distanceToSegment(occluder.center, camera, face.center) < occluder.radius + face.radius
            }
            : []
        let width = Float(frame.width)
        let height = Float(frame.height)
        let edgeScale = 0.12 * min(width, height)

        for row in 0 ..< face.rows {
            for column in 0 ..< face.columns {
                let point = face.point(column: column, row: row)
                let ray = point - camera
                let distance = simd_length(ray)
                guard distance > 0.15, distance < maxDistance else { continue }
                let cosine = -simd_dot(ray, face.normal) / distance
                guard cosine > 0.17 else { continue }

                let local = frame.worldToCamera * SIMD4<Float>(point, 1)
                let z = -local.z
                guard z > 0.1 else { continue }
                let px = frame.focal.x * local.x / z + frame.principal.x
                let py = frame.focal.y * -local.y / z + frame.principal.y
                guard px >= 1, py >= 1, px < width - 2, py < height - 2 else { continue }

                if let depth = frame.depth, let confidence = frame.depthConfidence {
                    let dx = min(frame.depthWidth - 1, Int(px * Float(frame.depthWidth) / width))
                    let dy = min(frame.depthHeight - 1, Int(py * Float(frame.depthHeight) / height))
                    let depthIndex = dy * frame.depthWidth + dx
                    let measured = depth[depthIndex]
                    let conf = confidence[depthIndex]
                    
                    // Only use high-confidence depth (2 = high, 1 = medium, 0 = low)
                    if measured.isFinite, measured > 0, conf >= 2 {
                        if measured < z - max(0.05, 0.03 * z) { continue }   // something stands in front
                        // Tightened tolerance: was +25cm/10%, now +8cm/4% to reduce off-box clutter
                        if measured > z + max(0.08, 0.04 * z) { continue }   // the surface isn't really there
                    }
                } else if blockers.contains(where: { $0.hits(origin: camera, direction: ray / distance, maxT: distance - 0.12) }) {
                    continue
                }

                let color = sample(frame, x: px, y: py, toLinear: toLinear)
                let edge = min(1, min(min(px, width - px), min(py, height - py)) / edgeScale)
                let base = cosine * cosine / max(distance * distance, 0.25) * (0.25 + 0.75 * edge)
                
                // Weight includes sharpness: prefer sharp, head-on, close views
                // Sharpness is variance of Laplacian, typically 0-10000+; normalize to ~0-1 range
                let sharpnessBoost = 1.0 + min(1.0, frame.sharpness / 2000.0)
                let weight = base * base * sharpnessBoost
                
                let texelIndex = face.offset + row * face.columns + column
                // Best-view selection: keep only the highest-weight view per texel
                if weight > bestViews[texelIndex].weight {
                    bestViews[texelIndex] = (color, weight, frameIndex)
                }
            }
        }
    }

    private static func projectedBoundsOverlap(face: Face, frame: FrameData) -> Bool {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var behind = 0
        let unitCorners: [SIMD2<Float>] = [SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5)]
        let corners = unitCorners.map { corner in
            face.center + face.uAxis * (corner.x * face.width) + face.vAxis * (corner.y * face.height)
        }
        for corner in corners {
            let local = frame.worldToCamera * SIMD4<Float>(corner, 1)
            let z = -local.z
            if z < 0.1 {
                behind += 1
                continue
            }
            let px = frame.focal.x * local.x / z + frame.principal.x
            let py = frame.focal.y * -local.y / z + frame.principal.y
            minX = min(minX, px)
            maxX = max(maxX, px)
            minY = min(minY, py)
            maxY = max(maxY, py)
        }
        if behind == corners.count { return false }
        // A face crossing the camera plane can't be bounded reliably; let per-texel tests decide.
        if behind > 0 { return true }
        return maxX >= 0 && minX <= Float(frame.width) && maxY >= 0 && minY <= Float(frame.height)
    }

    private static func sample(_ frame: FrameData, x: Float, y: Float, toLinear: [Float]) -> SIMD3<Float> {
        let fx = x - 0.5
        let fy = y - 0.5
        let x0 = max(0, Int(fx))
        let y0 = max(0, Int(fy))
        let x1 = min(frame.width - 1, x0 + 1)
        let y1 = min(frame.height - 1, y0 + 1)
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)
        func pixel(_ px: Int, _ py: Int) -> SIMD3<Float> {
            let i = (py * frame.width + px) * 4
            return SIMD3<Float>(toLinear[Int(frame.pixels[i])], toLinear[Int(frame.pixels[i + 1])], toLinear[Int(frame.pixels[i + 2])])
        }
        let top = pixel(x0, y0) * (1 - tx) + pixel(x1, y0) * tx
        let bottom = pixel(x0, y1) * (1 - tx) + pixel(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    private static func distanceToSegment(_ point: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-8 else { return simd_distance(point, a) }
        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        return simd_distance(point, a + ab * t)
    }

    // MARK: Finishing and atlas

    struct FinishedFace {
        let face: Face
        /// Linear RGB per texel, holes filled.
        let texels: [SIMD3<Float>]
        let averageColor: SIMD3<Float>?
        let coverage: Float
        let seenTexels: Int
    }

    private static func finish(faces: [Face], bestViews: [(color: SIMD3<Float>, weight: Float, frameIndex: Int)]) -> [FinishedFace] {
        faces.map { face in
            let count = face.columns * face.rows
            var texels = [SIMD3<Float>](repeating: .zero, count: count)
            var filled = [Bool](repeating: false, count: count)
            var sum = SIMD3<Float>.zero
            var seen = 0
            for index in 0 ..< count {
                let view = bestViews[face.offset + index]
                guard view.weight > 0 else { continue }
                texels[index] = view.color
                filled[index] = true
                sum += view.color
                seen += 1
            }
            guard seen > 0 else {
                return FinishedFace(face: face, texels: texels, averageColor: nil, coverage: 0, seenTexels: 0)
            }
            let average = sum / Float(seen)

            // Grow seen texels into unseen gaps, then fall back to the face's average color.
            for _ in 0 ..< 24 {
                var grew = false
                var next = filled
                for row in 0 ..< face.rows {
                    for column in 0 ..< face.columns {
                        let index = row * face.columns + column
                        guard !filled[index] else { continue }
                        var neighborSum = SIMD3<Float>.zero
                        var neighbors = 0
                        for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let c = column + dc
                            let r = row + dr
                            guard c >= 0, r >= 0, c < face.columns, r < face.rows else { continue }
                            let n = r * face.columns + c
                            if filled[n] {
                                neighborSum += texels[n]
                                neighbors += 1
                            }
                        }
                        if neighbors > 0 {
                            texels[index] = neighborSum / Float(neighbors)
                            next[index] = true
                            grew = true
                        }
                    }
                }
                filled = next
                if !grew { break }
            }
            for index in 0 ..< count where !filled[index] { texels[index] = average }
            return FinishedFace(face: face, texels: texels, averageColor: average, coverage: Float(seen) / Float(count), seenTexels: seen)
        }
    }

    private struct Atlas {
        let jpeg: Data
        let width: Int
        let height: Int
        /// Rect per face, keyed by the face's accumulator offset.
        let rects: [Int: [Int]]
    }

    private static func packAtlas(_ faces: [FinishedFace]) -> Atlas? {
        let textured = faces.filter { $0.averageColor != nil && $0.coverage >= 0.03 }
            .sorted { $0.face.rows > $1.face.rows }
        let padding = atlasPadding
        let area = textured.reduce(0) { $0 + ($1.face.columns + 2 * padding) * ($1.face.rows + 2 * padding) }
        // Increased atlas size threshold for higher resolution
        let width = area > 4096 * 1400 ? 8192 : area > 2048 * 1400 ? 4096 : 2048

        var rects = [Int: [Int]]()
        var x = 0
        var y = 0
        var shelfHeight = 0
        for item in textured {
            let w = item.face.columns + 2 * padding
            let h = item.face.rows + 2 * padding
            if x + w > width {
                x = 0
                y += shelfHeight
                shelfHeight = 0
            }
            rects[item.face.offset] = [x + padding, y + padding, item.face.columns, item.face.rows]
            x += w
            shelfHeight = max(shelfHeight, h)
        }
        let height = max(4, y + shelfHeight)

        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for item in textured {
            guard let rect = rects[item.face.offset] else { continue }
            let columns = item.face.columns
            let rows = item.face.rows
            // Padding repeats the edge texels so filtering and JPEG blocks don't bleed neighboring faces.
            for py in -padding ..< rows + padding {
                for px in -padding ..< columns + padding {
                    let source = item.texels[min(rows - 1, max(0, py)) * columns + min(columns - 1, max(0, px))]
                    let index = ((rect[1] + py) * width + rect[0] + px) * 4
                    pixels[index] = UInt8(max(0, min(255, (linearToSRGB(source.x) * 255).rounded())))
                    pixels[index + 1] = UInt8(max(0, min(255, (linearToSRGB(source.y) * 255).rounded())))
                    pixels[index + 2] = UInt8(max(0, min(255, (linearToSRGB(source.z) * 255).rounded())))
                    pixels[index + 3] = 255
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Atlas(jpeg: output as Data, width: width, height: height, rects: rects)
    }

    private static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ l: Float) -> Float {
        let c = max(0, min(1, l))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    
    // MARK: - Exposure Normalization
    
    /// Compute per-frame gain factors to normalize exposure across all keyframes.
    /// Uses a reference frame (median exposure) and solves for relative gains based on overlapping texels.
    private static func computeExposureGains(
        keyframes: [ColorKeyframe],
        bestViews: UnsafeMutableBufferPointer<(color: SIMD3<Float>, weight: Float, frameIndex: Int)>,
        faces: [Face]
    ) -> [Float] {
        guard keyframes.count > 1 else { return [1.0] }
        
        // Collect exposure durations to find median (reference frame)
        let exposures = keyframes.map { $0.exposureDuration }
        let sortedExposures = exposures.sorted()
        let medianExposure = sortedExposures[sortedExposures.count / 2]
        let referenceFrame = exposures.firstIndex(of: medianExposure) ?? 0
        
        // Build a graph of overlapping views: which frames see which texels
        var frameOverlaps: [[Int]] = Array(repeating: [], count: keyframes.count)
        var texelsPerFrame: [Int] = Array(repeating: 0, count: keyframes.count)
        
        for face in faces {
            for row in 0 ..< face.rows {
                for column in 0 ..< face.columns {
                    let texelIndex = face.offset + row * face.columns + column
                    let view = bestViews[texelIndex]
                    guard view.weight > 0, view.frameIndex >= 0 else { continue }
                    texelsPerFrame[view.frameIndex] += 1
                }
            }
        }
        
        // Initial gains based on exposure duration relative to reference
        var gains = keyframes.enumerated().map { index, keyframe -> Float in
            let ratio = keyframe.exposureDuration / max(0.001, keyframes[referenceFrame].exposureDuration)
            return 1.0 / max(0.1, min(10.0, ratio))
        }
        gains[referenceFrame] = 1.0
        
        // Iterative refinement: adjust gains based on brightness differences in overlapping regions
        // This is a simplified version; full implementation would solve a sparse linear system
        for iteration in 0 ..< 5 {
            var newGains = gains
            var frameBrightness: [Float] = Array(repeating: 0, count: keyframes.count)
            var frameWeights: [Float] = Array(repeating: 0, count: keyframes.count)
            
            // Measure average brightness per frame
            for face in faces {
                for row in 0 ..< face.rows {
                    for column in 0 ..< face.columns {
                        let texelIndex = face.offset + row * face.columns + column
                        let view = bestViews[texelIndex]
                        guard view.weight > 0, view.frameIndex >= 0 else { continue }
                        let luma = 0.299 * view.color.x + 0.587 * view.color.y + 0.114 * view.color.z
                        frameBrightness[view.frameIndex] += luma * gains[view.frameIndex]
                        frameWeights[view.frameIndex] += 1
                    }
                }
            }
            
            // Compute target brightness (median of all frames)
            var validBrightness: [Float] = []
            for i in 0 ..< keyframes.count where frameWeights[i] > 10 {
                validBrightness.append(frameBrightness[i] / frameWeights[i])
            }
            guard !validBrightness.isEmpty else { break }
            validBrightness.sort()
            let targetBrightness = validBrightness[validBrightness.count / 2]
            
            // Adjust gains to match target brightness
            for i in 0 ..< keyframes.count where frameWeights[i] > 10 {
                let currentBrightness = frameBrightness[i] / frameWeights[i]
                if currentBrightness > 0.01 {
                    let adjustment = targetBrightness / currentBrightness
                    newGains[i] = gains[i] * adjustment
                    // Clamp to reasonable range
                    newGains[i] = max(0.2, min(5.0, newGains[i]))
                }
            }
            newGains[referenceFrame] = 1.0
            
            gains = newGains
        }
        
        return gains
    }
    
    /// Apply exposure gains to normalize brightness across all views.
    private static func applyExposureNormalization(
        bestViews: inout UnsafeMutableBufferPointer<(color: SIMD3<Float>, weight: Float, frameIndex: Int)>,
        gains: [Float]
    ) {
        for index in 0 ..< bestViews.count {
            let view = bestViews[index]
            guard view.weight > 0, view.frameIndex >= 0, view.frameIndex < gains.count else { continue }
            let gain = gains[view.frameIndex]
            bestViews[index].color = SIMD3<Float>(
                min(1.0, view.color.x * gain),
                min(1.0, view.color.y * gain),
                min(1.0, view.color.z * gain)
            )
        }
    }
    
    // MARK: - Seam Leveling
    
    /// Apply seam leveling to reduce visible color discontinuities between adjacent faces.
    /// Uses a simple gain-adjustment approach along shared edges.
    private static func applySeamLeveling(
        faces: [Face],
        bestViews: UnsafeMutableBufferPointer<(color: SIMD3<Float>, weight: Float, frameIndex: Int)>,
        surfaces: [BakeSurface]
    ) -> [(color: SIMD3<Float>, weight: Float, frameIndex: Int)] {
        var result = Array(bestViews)
        
        // Find adjacent faces (faces of the same surface)
        var surfaceFaces: [[Int]] = Array(repeating: [], count: surfaces.count)
        for (index, face) in faces.enumerated() {
            surfaceFaces[face.surfaceIndex].append(index)
        }
        
        // For each surface with multiple faces, level seams between them
        for faceIndices in surfaceFaces where faceIndices.count > 1 {
            // Level seams between all pairs of faces on this surface
            for i in 0 ..< faceIndices.count {
                for j in (i + 1) ..< faceIndices.count {
                    levelSeamBetween(
                        faceA: faces[faceIndices[i]],
                        faceB: faces[faceIndices[j]],
                        bestViews: &result
                    )
                }
            }
        }
        
        return result
    }
    
    /// Level the seam between two faces by adjusting edge pixels to minimize brightness differences.
    private static func levelSeamBetween(
        faceA: Face,
        faceB: Face,
        bestViews: inout [(color: SIMD3<Float>, weight: Float, frameIndex: Int)]
    ) {
        // Check if faces are adjacent (share an edge)
        // Simplified: adjust edges of both faces toward each other
        
        // Collect edge samples from both faces
        var edgeSamplesA: [(index: Int, color: SIMD3<Float>)] = []
        var edgeSamplesB: [(index: Int, color: SIMD3<Float>)] = []
        
        // Sample edges of face A
        for column in 0 ..< faceA.columns {
            // Top edge
            let topIndex = faceA.offset + column
            if bestViews[topIndex].weight > 0 {
                edgeSamplesA.append((topIndex, bestViews[topIndex].color))
            }
            // Bottom edge
            let bottomIndex = faceA.offset + (faceA.rows - 1) * faceA.columns + column
            if bestViews[bottomIndex].weight > 0 {
                edgeSamplesA.append((bottomIndex, bestViews[bottomIndex].color))
            }
        }
        for row in 0 ..< faceA.rows {
            // Left edge
            let leftIndex = faceA.offset + row * faceA.columns
            if bestViews[leftIndex].weight > 0 {
                edgeSamplesA.append((leftIndex, bestViews[leftIndex].color))
            }
            // Right edge
            let rightIndex = faceA.offset + row * faceA.columns + (faceA.columns - 1)
            if bestViews[rightIndex].weight > 0 {
                edgeSamplesA.append((rightIndex, bestViews[rightIndex].color))
            }
        }
        
        // Sample edges of face B
        for column in 0 ..< faceB.columns {
            let topIndex = faceB.offset + column
            if bestViews[topIndex].weight > 0 {
                edgeSamplesB.append((topIndex, bestViews[topIndex].color))
            }
            let bottomIndex = faceB.offset + (faceB.rows - 1) * faceB.columns + column
            if bestViews[bottomIndex].weight > 0 {
                edgeSamplesB.append((bottomIndex, bestViews[bottomIndex].color))
            }
        }
        for row in 0 ..< faceB.rows {
            let leftIndex = faceB.offset + row * faceB.columns
            if bestViews[leftIndex].weight > 0 {
                edgeSamplesB.append((leftIndex, bestViews[leftIndex].color))
            }
            let rightIndex = faceB.offset + row * faceB.columns + (faceB.columns - 1)
            if bestViews[rightIndex].weight > 0 {
                edgeSamplesB.append((rightIndex, bestViews[rightIndex].color))
            }
        }
        
        guard !edgeSamplesA.isEmpty, !edgeSamplesB.isEmpty else { return }
        
        // Compute average edge brightness for both faces
        let avgBrightnessA = edgeSamplesA.reduce(Float(0)) { sum, sample in
            sum + (0.299 * sample.color.x + 0.587 * sample.color.y + 0.114 * sample.color.z)
        } / Float(edgeSamplesA.count)
        
        let avgBrightnessB = edgeSamplesB.reduce(Float(0)) { sum, sample in
            sum + (0.299 * sample.color.x + 0.587 * sample.color.y + 0.114 * sample.color.z)
        } / Float(edgeSamplesB.count)
        
        guard avgBrightnessA > 0.01, avgBrightnessB > 0.01 else { return }
        
        // Compute target brightness (average of both)
        let targetBrightness = (avgBrightnessA + avgBrightnessB) / 2
        
        // Apply gentle gain adjustment to edges (70% toward target, 30% original)
        let gainA = 0.7 * (targetBrightness / avgBrightnessA) + 0.3
        let gainB = 0.7 * (targetBrightness / avgBrightnessB) + 0.3
        
        // Clamp gains to avoid extreme adjustments
        let clampedGainA = max(0.85, min(1.15, gainA))
        let clampedGainB = max(0.85, min(1.15, gainB))
        
        // Apply gains to edge pixels with feathering (stronger at edge, weaker inside)
        let featherWidth = 3
        
        // Feather face A edges
        for row in 0 ..< min(featherWidth, faceA.rows) {
            let feather = Float(featherWidth - row) / Float(featherWidth)
            let gain = 1.0 + (clampedGainA - 1.0) * feather
            for column in 0 ..< faceA.columns {
                let index = faceA.offset + row * faceA.columns + column
                applyGain(to: &bestViews[index], gain: gain)
                
                let bottomRow = faceA.rows - 1 - row
                let bottomIndex = faceA.offset + bottomRow * faceA.columns + column
                applyGain(to: &bestViews[bottomIndex], gain: gain)
            }
        }
        for column in 0 ..< min(featherWidth, faceA.columns) {
            let feather = Float(featherWidth - column) / Float(featherWidth)
            let gain = 1.0 + (clampedGainA - 1.0) * feather
            for row in 0 ..< faceA.rows {
                let index = faceA.offset + row * faceA.columns + column
                applyGain(to: &bestViews[index], gain: gain)
                
                let rightColumn = faceA.columns - 1 - column
                let rightIndex = faceA.offset + row * faceA.columns + rightColumn
                applyGain(to: &bestViews[rightIndex], gain: gain)
            }
        }
        
        // Feather face B edges
        for row in 0 ..< min(featherWidth, faceB.rows) {
            let feather = Float(featherWidth - row) / Float(featherWidth)
            let gain = 1.0 + (clampedGainB - 1.0) * feather
            for column in 0 ..< faceB.columns {
                let index = faceB.offset + row * faceB.columns + column
                applyGain(to: &bestViews[index], gain: gain)
                
                let bottomRow = faceB.rows - 1 - row
                let bottomIndex = faceB.offset + bottomRow * faceB.columns + column
                applyGain(to: &bestViews[bottomIndex], gain: gain)
            }
        }
        for column in 0 ..< min(featherWidth, faceB.columns) {
            let feather = Float(featherWidth - column) / Float(featherWidth)
            let gain = 1.0 + (clampedGainB - 1.0) * feather
            for row in 0 ..< faceB.rows {
                let index = faceB.offset + row * faceB.columns + column
                applyGain(to: &bestViews[index], gain: gain)
                
                let rightColumn = faceB.columns - 1 - column
                let rightIndex = faceB.offset + row * faceB.columns + rightColumn
                applyGain(to: &bestViews[rightIndex], gain: gain)
            }
        }
    }
    
    private static func applyGain(
        to view: inout (color: SIMD3<Float>, weight: Float, frameIndex: Int),
        gain: Float
    ) {
        guard view.weight > 0 else { return }
        view.color = SIMD3<Float>(
            min(1.0, view.color.x * gain),
            min(1.0, view.color.y * gain),
            min(1.0, view.color.z * gain)
        )
    }
}
