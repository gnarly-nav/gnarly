# Gnarly Textured Mesh Worker

This directory contains the server-side texturing pipeline that converts ARKit scene reconstruction meshes + captured keyframes into textured GLB files for rendering in the web viewer and Unity navigator.

## Overview

The mapper iOS app captures:
- **ARKit scene reconstruction mesh** (real geometry from LiDAR)
- **Keyframes** (photos with camera poses, intrinsics, and depth)

The texturing worker:
1. Takes the mesh and keyframes as input (exported in `mesh-bundle/`)
2. Runs **mvs-texturing** (Waechter et al. 2014) to select per-triangle texture patches from keyframes with view selection and seam leveling
3. Outputs a **GLB** file with compressed textures (KTX2/Basis or JPEG)
4. Generates `textured-mesh.json` metadata conforming to `shared/textured-mesh.schema.json`

## Building the Docker Image

```bash
cd texturing-worker
docker build -t gnarly-texturing-worker .
```

## Running the Worker

```bash
docker run -v /path/to/mesh-bundle:/input -v /path/to/output:/output \
  gnarly-texturing-worker /input /output --texture-format jpeg
```

**Input structure** (`/input/mesh-bundle/`):
```
mesh.obj                # ARKit scene reconstruction mesh in world coords
keyframes.json          # Camera poses, intrinsics, keyframe metadata
keyframes/
  frame_0000.jpg        # Captured photos
  frame_0000.depth      # Optional: LiDAR depth (Float32 binary)
  ...
```

**Output** (`/output/`):
```
textured-mesh.glb       # GLB with textured mesh
textured-mesh.json      # Metadata (conforms to textured-mesh.schema.json)
```

## Integration with gnarly API

The texturing worker can be triggered:
1. **After zone publish**: The API detects a new `mesh-bundle/` in the uploaded package and spawns a texturing job
2. **Manual trigger**: An admin/API endpoint starts texturing for an existing zone

The API should:
- Download the mesh bundle from Firebase Storage
- Run the worker (local Docker or Cloud Run job)
- Upload `textured-mesh.glb` and `textured-mesh.json` to the zone's storage path
- Update the zone's `ZoneRecord` with `texturedMeshPath` and `texturedMeshMetadataPath`

## Production Considerations

1. **GLB Conversion**: The prototype uses a placeholder OBJ->GLB converter. For production:
   - Use **gltf-pipeline** or **Blender Python API** to convert mvs-texturing's OBJ output to GLB
   - Compress textures to **KTX2/Basis Universal** for smaller downloads and web/Unity compatibility

2. **Texture Optimization**:
   - mvs-texturing produces multiple texture files; consolidate them into a single atlas
   - Apply **Basis Universal** supercompression for KTX2 (70-80% smaller than JPEG)
   - Set texture resolution limits (e.g., 2048×2048 max)

3. **Depth Integration**:
   - mvs-texturing doesn't natively use LiDAR depth for occlusion handling
   - Consider **OpenMVS TextureMesh** as an alternative (supports depth-based visibility)
   - Or preprocess keyframes to mask occluded regions using depth

4. **Cloud Deployment**:
   - Deploy as a **Cloud Run** job or **Kubernetes Job**
   - Use **Pub/Sub** to trigger on new zone uploads
   - Store intermediate work in ephemeral disks to avoid storage costs

5. **Fallback**:
   - If texturing fails (not enough keyframes, mesh quality issues), the system should fall back to the existing `surface-colors.json` box-based textures

## mvs-texturing Reference

- Paper: Waechter et al. 2014, "Let There Be Color! Large-Scale Texturing of 3D Reconstructions"
- Code: https://github.com/nmoehrle/mvs-texturing
- License: BSD 3-Clause

## Testing Locally

To test the pipeline without Docker:

```bash
# Install dependencies
sudo apt-get install build-essential cmake git libeigen3-dev libpng-dev libjpeg-dev
pip3 install numpy Pillow pygltflib

# Build mvs-texturing
git clone https://github.com/nmoehrle/mvs-texturing.git
cd mvs-texturing && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)
sudo cp apps/texrecon/texrecon /usr/local/bin/

# Run the pipeline
cd /path/to/gnarly/texturing-worker
python3 pipeline/texture_zone.py /path/to/mesh-bundle /path/to/output
```

## TODO (Follow-up Work)

- [ ] Implement robust OBJ->GLB conversion (use gltf-pipeline or Blender)
- [ ] Add KTX2/Basis Universal texture compression
- [ ] Integrate LiDAR depth into mvs-texturing or switch to OpenMVS
- [ ] Deploy as Cloud Run job with Pub/Sub trigger
- [ ] Add retry logic and error handling for failed texturing
- [ ] Metrics: track texturing time, texture size, keyframe usage
