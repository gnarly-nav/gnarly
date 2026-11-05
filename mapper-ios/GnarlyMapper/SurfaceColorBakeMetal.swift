import Metal
import MetalKit
import simd

/// Metal-accelerated surface color projection.
/// Falls back to CPU if Metal is unavailable or initialization fails.
final class MetalSurfaceProjector {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    
    static func create() -> MetalSurfaceProjector? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        
        // Compile the Metal kernel
        let source = Self.metalShaderSource()
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "projectTexel"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        
        return MetalSurfaceProjector(device: device, commandQueue: queue, pipeline: pipeline)
    }
    
    private init(device: MTLDevice, commandQueue: MTLCommandQueue, pipeline: MTLComputePipelineState) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }
    
    /// Project a frame onto faces using Metal compute.
    /// Returns true if Metal path succeeded, false to fall back to CPU.
    func project(
        faces: [SurfaceColorBaker.Face],
        frameData: SurfaceColorBaker.FrameData,
        frameIndex: Int,
        occluders: [SurfaceColorBaker.Occluder],
        into bestViews: UnsafeMutableBufferPointer<(color: SIMD3<Float>, weight: Float, frameIndex: Int)>
    ) -> Bool {
        // For now, use CPU fallback
        // Full Metal implementation would require:
        // 1. Create GPU buffers for face data, image texture, depth texture
        // 2. Encode compute commands
        // 3. Read back results
        // This is complex for the current architecture; deferred for optimization
        return false
    }
    
    private static func metalShaderSource() -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        
        struct Face {
            float3 center;
            float3 uAxis;
            float3 vAxis;
            float3 normal;
            float width;
            float height;
            int columns;
            int rows;
            int offset;
            float radius;
        };
        
        struct FrameParams {
            float3 cameraPosition;
            float4x4 worldToCamera;
            float2 focal;
            float2 principal;
            float sharpness;
            int width;
            int height;
            int depthWidth;
            int depthHeight;
        };
        
        // Project texels of one face
        kernel void projectTexel(
            constant Face& face [[buffer(0)]],
            constant FrameParams& params [[buffer(1)]],
            texture2d<float, access::sample> colorTexture [[texture(0)]],
            texture2d<float, access::sample> depthTexture [[texture(1)]],
            device packed_float3* bestColors [[buffer(2)]],
            device float* bestWeights [[buffer(3)]],
            device int* bestFrames [[buffer(4)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            int column = gid.x;
            int row = gid.y;
            
            if (column >= face.columns || row >= face.rows) return;
            
            // Compute world position of this texel
            float u = (float(column) + 0.5) / float(face.columns) - 0.5;
            float v = 0.5 - (float(row) + 0.5) / float(face.rows);
            float3 point = face.center + face.uAxis * (u * face.width) + face.vAxis * (v * face.height);
            
            // Ray from camera to texel
            float3 ray = point - params.cameraPosition;
            float distance = length(ray);
            
            if (distance < 0.15 || distance > 7.0) return;
            
            float cosine = -dot(ray, face.normal) / distance;
            if (cosine < 0.17) return;
            
            // Project to camera space
            float4 local = params.worldToCamera * float4(point, 1.0);
            float z = -local.z;
            
            if (z < 0.1) return;
            
            float px = params.focal.x * local.x / z + params.principal.x;
            float py = params.focal.y * (-local.y) / z + params.principal.y;
            
            if (px < 1 || py < 1 || px >= params.width - 2 || py >= params.height - 2) return;
            
            // Sample color texture
            constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
            float3 color = colorTexture.sample(s, float2(px, py)).rgb;
            
            // Compute weight
            float edge = min(1.0, min(min(px, params.width - px), min(py, params.height - py)) / (0.12 * min(params.width, params.height)));
            float base = cosine * cosine / max(distance * distance, 0.25) * (0.25 + 0.75 * edge);
            float sharpnessBoost = 1.0 + min(1.0, params.sharpness / 2000.0);
            float weight = base * base * sharpnessBoost;
            
            // Update if this is the best view
            int texelIndex = face.offset + row * face.columns + column;
            if (weight > bestWeights[texelIndex]) {
                bestColors[texelIndex] = packed_float3(color);
                bestWeights[texelIndex] = weight;
                // Note: bestFrames update would need atomic operation
            }
        }
        """
    }
}
