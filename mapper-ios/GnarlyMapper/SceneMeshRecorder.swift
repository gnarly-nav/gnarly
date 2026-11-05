import ARKit
import Foundation
import ModelIO
import SceneKit
import simd

/// Captures ARKit scene reconstruction mesh alongside RoomPlan for server-side texturing.
/// The LiDAR mesh provides real geometry (clutter, furniture shape) that RoomPlan's idealized boxes don't model.
final class SceneMeshRecorder {
    private let queue = DispatchQueue(label: "com.gnarly.mapper.scene-mesh", qos: .utility)
    private let lock = NSLock()
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var generation = 0
    
    private(set) var capturedMeshCount = 0
    
    var hasCapture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !meshAnchors.isEmpty
    }
    
    func reset() {
        lock.lock()
        meshAnchors.removeAll()
        generation += 1
        capturedMeshCount = 0
        lock.unlock()
    }
    
    /// Call when ARSession adds or updates mesh anchors.
    func update(meshAnchors: [ARMeshAnchor]) {
        lock.lock()
        defer { lock.unlock() }
        for anchor in meshAnchors {
            self.meshAnchors[anchor.identifier] = anchor
        }
        capturedMeshCount = self.meshAnchors.count
    }
    
    /// Export the accumulated mesh as OBJ text (vertices and faces in ARKit world coords).
    /// Returns (obj content, vertex count, face count) or nil if no mesh captured.
    func exportOBJ() -> (String, Int, Int)? {
        lock.lock()
        let anchors = Array(meshAnchors.values)
        lock.unlock()
        
        guard !anchors.isEmpty else { return nil }
        
        var objLines = ["# ARKit scene reconstruction mesh"]
        var vertexCount = 0
        var faceCount = 0
        
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            
            let vertices = geometry.vertices
            let faces = geometry.faces
            
            objLines.append("# Mesh anchor \(anchor.identifier)")
            
            for i in 0..<vertices.count {
                let localVertex = vertices[i]
                let worldVertex = simd_mul(transform, simd_float4(localVertex.x, localVertex.y, localVertex.z, 1))
                objLines.append("v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)")
            }
            
            let indexBuffer = faces.buffer.contents()
            let bytesPerIndex = faces.bytesPerIndex
            
            for i in 0..<faces.count {
                let offset = i * 3 * bytesPerIndex
                let i0: Int
                let i1: Int
                let i2: Int
                
                if bytesPerIndex == 2 {
                    let ptr = indexBuffer.advanced(by: offset).assumingMemoryBound(to: UInt16.self)
                    i0 = Int(ptr[0])
                    i1 = Int(ptr[1])
                    i2 = Int(ptr[2])
                } else {
                    let ptr = indexBuffer.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
                    i0 = Int(ptr[0])
                    i1 = Int(ptr[1])
                    i2 = Int(ptr[2])
                }
                
                objLines.append("f \(vertexCount + i0 + 1) \(vertexCount + i1 + 1) \(vertexCount + i2 + 1)")
            }
            
            vertexCount += vertices.count
            faceCount += faces.count
        }
        
        return (objLines.joined(separator: "\n"), vertexCount, faceCount)
    }
    
    /// Export mesh and keyframe metadata for server-side texturing.
    /// Writes mesh.obj, keyframes.json (camera poses/intrinsics), and copies keyframe images + depth.
    /// Returns the directory URL containing the mesh bundle, or nil if no mesh captured.
    func exportBundle(
        keyframes: [ColorKeyframe],
        coordinateSystem: String = "arkit-world-meters"
    ) -> URL? {
        guard let (objContent, vertexCount, faceCount) = exportOBJ() else { return nil }
        
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnarly-mesh-\(UUID().uuidString)", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            let meshURL = directory.appendingPathComponent("mesh.obj")
            try objContent.write(to: meshURL, atomically: true, encoding: .utf8)
            
            let metadata: [String: Any] = [
                "coordinateSystem": coordinateSystem,
                "vertexCount": vertexCount,
                "faceCount": faceCount,
                "keyframes": keyframes.map { frame in
                    var dict: [String: Any] = [
                        "image": frame.imageURL.lastPathComponent,
                        "width": frame.width,
                        "height": frame.height,
                        "focal": [frame.focal.x, frame.focal.y],
                        "principal": [frame.principal.x, frame.principal.y],
                    ]
                    
                    let t = frame.cameraTransform
                    dict["transform"] = [
                        [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w],
                        [t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w],
                        [t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w],
                        [t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w],
                    ]
                    
                    if let depthURL = frame.depthURL {
                        dict["depth"] = depthURL.lastPathComponent
                        dict["depthWidth"] = frame.depthWidth
                        dict["depthHeight"] = frame.depthHeight
                    }
                    
                    return dict
                }
            ]
            
            let metadataURL = directory.appendingPathComponent("keyframes.json")
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: metadataURL)
            
            let keyframesDir = directory.appendingPathComponent("keyframes", isDirectory: true)
            try FileManager.default.createDirectory(at: keyframesDir, withIntermediateDirectories: true)
            
            for frame in keyframes {
                let destImage = keyframesDir.appendingPathComponent(frame.imageURL.lastPathComponent)
                try? FileManager.default.copyItem(at: frame.imageURL, to: destImage)
                
                if let depthURL = frame.depthURL {
                    let destDepth = keyframesDir.appendingPathComponent(depthURL.lastPathComponent)
                    try? FileManager.default.copyItem(at: depthURL, to: destDepth)
                }
            }
            
            return directory
        } catch {
            return nil
        }
    }
}
