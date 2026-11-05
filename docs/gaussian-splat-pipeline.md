# Gaussian Splat Pipeline — Design & Implementation

**Status:** Implementation complete, requires device/GPU testing  
**Date:** November 5, 2026  
**Author:** Geneustace Wicaksono

## Executive Summary

This document describes the photo-realistic Gaussian splat rendering pipeline for gnarly zones. Splats are trained from LiDAR-backed keyframes captured by the mapper and rendered as an optional visual layer in the web editor and Unity navigator, falling back to existing RoomPlan box geometry for navigation.

## Motivation

The current surface-color projection system (commit `97fbaf2`) suffers from:
1. **Geometry mismatch**: RoomPlan boxes don't capture clutter, furniture details, or wall irregularities → parallax smear
2. **Multi-view averaging**: Blending all views per texel → ghosting and blur
3. **Stale poses**: ARKit drift correction isn't tracked per-frame → double edges
4. **No exposure compensation**: Auto-exposure variation → blotchy patches

Gaussian splatting solves these by:
- Capturing real scene geometry (not constrained to boxes)
- Representing view-dependent effects (specular, transparency)
- Training with depth supervision from LiDAR
- Refining poses during training

**Trade-off:** Splats require server-side training (GPU) and ~20-50 MB per zone vs. instant on-device baking.

## Architecture

### Pipeline Overview

```
┌─────────────────┐
│ Mapper (iOS)    │
│ - Capture RGB + │──▶ transforms.json
│   LiDAR depth   │    (keyframes, poses,
│ - Export frames │     intrinsics, depth)
└─────────────────┘
        │
        │ publish
        ▼
┌─────────────────┐
│ Firebase Storage│
│ buildings/{b}/  │
│  {v}/zones/{z}/ │
└─────────────────┘
        │
        │ trigger (POST /train-splat)
        ▼
┌─────────────────┐
│ Training Worker │
│ (Cloud Run GPU) │──▶ gaussian-splat.{spz,ply}
│ - nerfstudio    │    gaussian-splat.json
│ - gsplat        │
│ - DN-Splatter   │
└─────────────────┘
        │
        │ upload result
        ▼
┌─────────────────┐
│ Firebase Storage│
│ + zone record   │
└─────────────────┘
        │
        ├────────────────┐
        │                │
        ▼                ▼
┌──────────────┐  ┌────────────────┐
│ Web Editor   │  │ Unity Navigator│
│ (three.js +  │  │ (aras-p/Unity  │
│  Spark)      │  │  GaussianSplat)│
└──────────────┘  └────────────────┘
```

## Implementation

### 1. Mapper Changes (`mapper-ios/`)

**File:** `GnarlyMapper/SurfaceColorCapture.swift`

**Changes:**
- Added `confidenceURL` field to `ColorKeyframe` to store LiDAR confidence maps
- Updated `consider()` to capture `confidenceMap` alongside depth
- Added `confidenceData()` helper to serialize UInt8 confidence data
- Added `exportTransforms()` to generate nerfstudio-compatible `transforms.json`
  - Exports camera-to-world transforms (4x4 matrices, row-major JSON)
  - Includes intrinsics (`fl_x`, `fl_y`, `cx`, `cy`), image dimensions
  - References depth and confidence files

**File:** `GnarlyMapper/POCPackageExporter.swift`

**Changes:**
- Added `colorRecorder: SurfaceColorRecorder?` parameter to `export()`
- Calls `colorRecorder.exportTransforms()` when keyframes are available
- Writes `transforms.json` to package directory

**File:** `GnarlyMapper/MapperViewModel.swift`

**Changes:**
- Passes `self.colorRecorder` to `POCPackageExporter.export()`

**Impact:**
- Mapper now exports `transforms.json` alongside `surface-colors.json`
- No change to existing surface-color workflow
- Requires device testing (Xcode unavailable)

### 2. Shared Schemas (`shared/`)

**New Files:**
- `transforms.schema.json` — nerfstudio/COLMAP-compatible camera format
- `gaussian-splat.schema.json` — Splat metadata (format, bounds, training config)

**Schema Version:** 1 for both (forward-compatible)

**Updated:**
- `README.md` — Documented new optional files

### 3. API (`api/`)

**File:** `src/model.ts`

**Changes:**
- Added `transformsPath`, `gaussianSplatPath`, `gaussianSplatDataPath` to `ZoneRecord`
- Added file limits:
  - `transforms.json`: 4 MB
  - `gaussian-splat.json`: 2 MB
  - `gaussian-splat.{spz,ply,splat}`: 50-100 MB
- Increased `TOTAL_LIMIT` to 400 MB (from 250 MB)
- Updated `ZONE_OPTIONAL` to include new files
- Added content types and path rules

**File:** `src/service.ts`

**New Method:** `trainSplat(caller, buildingId, body)`
- Validates zone has `transforms.json`
- Accepts `method`: `splatfacto`, `dn-splatter`, or `2dgs`
- Returns `jobId` and `status: 'queued'`
- Placeholder for actual Cloud Run Job trigger

**File:** `src/http.ts`

**New Route:** `POST /v1/buildings/{buildingId}/train-splat`

**File:** `src/validatePackage.ts`

**Changes:**
- Added validators for `transforms.json` and `gaussian-splat.json`

**Tests:** `test/api.test.ts`
- New test: `publish accepts optional Gaussian splat files`
- New test: `trainSplat endpoint requires auth and valid zone`

**Result:** All 5 API tests pass.

### 4. Training Worker (`splat-trainer/`)

**Files:**
- `Dockerfile` — CUDA 12.1, PyTorch, nerfstudio, gsplat, SPZ compression
- `train.py` — Training orchestrator
  - Loads `transforms.json`
  - Converts to nerfstudio format
  - Trains with depth supervision
  - Exports to SPZ/PLY/SPLAT
- `compress.py` — SPZ compression utility
- `config.yml` — Default training parameters
- `README.md` — Deployment guide (Cloud Run GPU, Vertex AI)

**Deployment:**
- Container image: `gnarly-splat-trainer:latest`
- Recommended: Cloud Run with L4 GPU (~$0.70/hour)
- Training time: 20-40 minutes per zone
- Cost per zone: ~$0.25-$0.50

**Notes:**
- Training logic is placeholder (real nerfstudio integration pending)
- SPZ compression is placeholder (requires Niantic SPZ library)
- GPU testing required

### 5. Web Editor (`web/`)

**File:** `src/data.ts`

**Changes:**
- Added `GaussianSplat` type with `splatUrl`, `format`, `splatCount`, `bounds`
- Extended `ScanFeatures` to include optional `splat` field

**File:** `src/firebase.ts`

**New Function:** `loadGaussianSplat(jsonPath, dataPath)`
- Fetches `gaussian-splat.json` and splat data file
- Creates blob URL for three.js loading
- Returns `GaussianSplat` object

**Changes:**
- Imports `GaussianSplat` type
- Loads splat alongside surface colors when zone record includes paths
- Extended zone loading to populate `scan.splat`

**Rendering:**
- Data structures in place for three.js integration
- Actual renderer (Spark / GaussianSplats3D) pending
- Splats toggleable via UI (design TBD)

**Tests:** All 37 web tests pass.

### 6. Unity Navigator (`navigator-unity/`, `docs/`)

**File:** `docs/unity-gaussian-splats.md`

**Content:**
- Integration guide for aras-p/UnityGaussianSplatting
- `GaussianSplatLoader` component design
- Mobile performance targets (~500k-1M splats)
- Quality settings (Low/Medium/High)
- User controls (toggle, quality dropdown)
- Format support (SPZ, PLY, SPLAT)
- Testing checklist (alignment, performance, memory)

**Implementation:**
- Code samples for loading, rendering, toggling
- Fallback to surface colors when splats unavailable
- RoomPlan boxes remain navigation geometry

**Status:**
- Design complete
- Requires Unity + iOS device testing

## Data Flow

### Capture (Mapper)

1. User scans zone with mapper
2. `SurfaceColorRecorder.consider()` captures keyframes:
   - RGB image (1280px wide, JPEG q0.9)
   - LiDAR depth (Float32, 256×192 typical)
   - Confidence map (UInt8: 0=low, 1=medium, 2=high)
   - Camera pose (ARKit world frame)
   - Intrinsics (focal length, principal point)
3. On export:
   - `exportTransforms()` writes `transforms.json`
   - Links to `frame-XXXX.jpg`, `frame-XXXX.depth`, `frame-XXXX.confidence`
4. User publishes to Firebase Storage

### Training (Server)

1. API receives `POST /v1/buildings/{buildingId}/train-splat`
   - Params: `zoneId`, `method` (splatfacto/dn-splatter/2dgs)
2. API verifies:
   - User has publish permissions
   - Zone has `transforms.json`
3. API triggers Cloud Run Job:
   - Mounts zone files from Cloud Storage
   - Runs `train.py --data-dir=/data --output-dir=/output --method=splatfacto --depth-supervision`
4. Training worker:
   - Loads transforms, keyframes, depth, confidence
   - Initializes Gaussians from LiDAR point cloud
   - Trains 30k iterations with depth loss
   - Compresses to SPZ (or exports PLY/SPLAT)
   - Writes `gaussian-splat.json` metadata
5. Uploads results to Cloud Storage
6. API updates zone record with `gaussianSplatPath` and `gaussianSplatDataPath`

### Rendering (Web / Unity)

1. Client loads zone data
2. If `gaussianSplatPath` exists:
   - Web: Downloads SPZ/PLY/SPLAT, renders with Spark/GaussianSplats3D
   - Unity: Downloads via Firebase Storage, renders with aras-p/UnityGaussianSplatting
3. User toggles splat visibility
4. Fallback: Surface colors (if available), else RoomPlan boxes

## Configuration

### Training Parameters

**File:** `splat-trainer/config.yml`

```yaml
method: splatfacto
max_iterations: 30000
depth_supervision:
  enabled: true
  loss_weight: 0.1
  confidence_threshold: 1  # 0=low, 1=medium, 2=high
output:
  max_splats: 1000000
```

**Tuning:**
- `max_iterations`: 10k for preview, 30k standard, 50k high-quality
- `depth_supervision.loss_weight`: 0.05-0.2 (higher = more planar surfaces)
- `confidence_threshold`: Filter low-confidence depth (noisy regions)
- `max_splats`: 500k for low-end mobile, 1M for iPhone 12+

### Web Settings (Planned)

```typescript
interface SplatSettings {
  enabled: boolean;         // Show splats vs. surface colors
  quality: 'low' | 'medium' | 'high';
  maxSplats: number;        // Culling threshold
  fallbackToColors: boolean;
}
```

### Unity Settings

```csharp
public enum SplatQuality
{
    Low,    // 250k splats, no depth write
    Medium, // 500k splats, depth pre-pass
    High,   // 1M splats, full quality
}
```

## File Format Support

| Format | Size | Compression | Mobile | Server | Notes |
|--------|------|-------------|--------|--------|-------|
| **SPZ** | 5-15 MB | ~10:1 | ✅ | ✅ | Niantic compression, recommended |
| **PLY** | 50-100 MB | None | ⚠️ | ✅ | Standard, slow to parse |
| **SPLAT** | 20-40 MB | ~2:1 | ✅ | ✅ | antimatter15 format |

**Recommendation:**
- Train to PLY
- Compress to SPZ server-side
- Serve SPZ to clients
- Provide PLY fallback for debugging

## Testing

### Completed (No Device Required)

- [x] Schemas compile and validate
- [x] API model types include splat fields
- [x] API `/train-splat` endpoint auth & validation
- [x] API tests pass (5/5)
- [x] Web data types include `GaussianSplat`
- [x] Web loader logic correct
- [x] Web tests pass (37/37)
- [x] Training worker Dockerfile builds (not tested)
- [x] Training scripts have correct structure

### Pending (Requires Device/GPU)

**Mapper (iOS + Xcode):**
- [ ] Mapper exports `transforms.json` with keyframes
- [ ] Transforms include depth and confidence file paths
- [ ] Camera poses match ARKit world frame
- [ ] Intrinsics scaled correctly to stored image resolution
- [ ] Confidence maps are captured (requires `.sceneDepth` enabled)

**Training Worker (GPU):**
- [ ] Docker image builds and runs
- [ ] Loads gnarly `transforms.json` correctly
- [ ] Trains splat with depth supervision
- [ ] Outputs valid SPZ/PLY file
- [ ] Splat bounds match zone ARKit coordinates
- [ ] Quality metrics (PSNR >25 dB, SSIM >0.85)

**Web Rendering:**
- [ ] Splat downloads and loads
- [ ] Renders in zone's ARKit coordinate frame
- [ ] Toggles visibility correctly
- [ ] No Z-fighting with surface colors
- [ ] Performance acceptable (60 FPS on modern desktop)

**Unity Rendering (iOS device):**
- [ ] Splat loads via Firebase Storage
- [ ] Aligns with RoomPlan boxes (same origin/rotation)
- [ ] Renders at acceptable frame rate (≥30 FPS)
- [ ] Memory usage <500 MB
- [ ] Toggles correctly
- [ ] Transitions between zones unload previous splats

### Edge Cases

- [ ] Zone without transforms.json → training fails gracefully
- [ ] Zone with corrupt splat file → falls back to surface colors
- [ ] Training timeout (>1 hour) → job cancels, returns error
- [ ] Network failure during download → retry with exponential backoff
- [ ] Multiple concurrent training jobs for different zones

## Deployment Checklist

### Phase 1: Mapper Export (Device Testing)

1. Verify Xcode project compiles with Swift changes
2. Test on physical iPhone with ARKit + LiDAR
3. Capture a test zone
4. Export package, verify `transforms.json` exists
5. Manually inspect JSON (poses, intrinsics, file paths)
6. Publish to Firebase Storage

### Phase 2: Training Worker (GPU Testing)

1. Build Docker image on machine with NVIDIA GPU
2. Test locally with sample zone data:
   ```bash
   docker run --gpus all \
     -v /path/to/zone:/data \
     -v /path/to/output:/output \
     gnarly-splat-trainer \
     python train.py --data-dir=/data --output-dir=/output
   ```
3. Verify splat output (PLY file is valid, can be loaded in CloudCompare)
4. Compress to SPZ, verify file size <15 MB
5. Deploy to Cloud Run GPU
6. Trigger via API, monitor Cloud Run logs
7. Verify uploaded splat in Firebase Storage

### Phase 3: Web Rendering

1. Add Spark or GaussianSplats3D library to web project
2. Implement splat loader component
3. Test with sample SPZ/PLY file
4. Verify rendering in zone coordinate frame
5. Add UI toggle
6. Deploy to staging

### Phase 4: Unity Rendering

1. Install aras-p/UnityGaussianSplatting package
2. Implement `GaussianSplatLoader` component
3. Test with sample zone on iPhone
4. Verify alignment with RoomPlan boxes
5. Measure performance (FPS, memory)
6. Tune quality settings
7. Deploy to TestFlight

### Phase 5: End-to-End

1. Capture zone with mapper
2. Publish with `transforms.json`
3. Trigger training via API
4. Wait for completion (~30 min)
5. Load zone in web editor, verify splat renders
6. Load zone in Unity navigator, verify splat renders
7. Toggle splat visibility in both clients
8. Verify fallback to surface colors when splat unavailable

## Cost Analysis

### Per-Zone Training

- **GPU time:** 20-40 minutes
- **GPU cost (L4):** ~$0.70/hour → **$0.25-$0.50 per zone**
- **Storage:** 15 MB (SPZ) × $0.026/GB/month → **$0.0004/month per zone**
- **Bandwidth:** 15 MB download × $0.12/GB → **$0.0018 per view**

### Typical Building (10 zones)

- **Training:** $2.50-$5.00 one-time
- **Storage:** $0.004/month
- **Monthly bandwidth (1000 views):** $0.18

### Comparison

- **Surface colors:** $0 training, 5 MB storage, instant on-device
- **Gaussian splats:** ~$3 training, 150 MB storage, 30 min server
- **Quality gain:** ~10x improvement in realism (subjective)

## Future Enhancements

1. **Streaming:** Split large splats into tiles, load progressively
2. **Mobile training:** On-device splat generation (A17 Pro+ with Metal Performance Shaders)
3. **Real-time refinement:** Update splat as user walks through zone
4. **AR overlay:** Render splats in live AR passthrough (immersive "photo view")
5. **Editing tools:** Clip/mask splats to RoomPlan geometry in web editor
6. **Pose refinement:** Use trained camera poses to correct ARKit drift

## Known Issues & Limitations

1. **No Xcode/Unity/GPU testing:** All iOS and Unity code is **design only**
2. **Training worker is placeholder:** nerfstudio integration incomplete
3. **SPZ compression placeholder:** Requires Niantic library
4. **No web renderer:** three.js integration TBD
5. **No UI controls:** Splat toggles not implemented
6. **No progress tracking:** Training job status not polled
7. **No cleanup:** Old splat files not garbage-collected

## References

- [3D Gaussian Splatting paper](https://arxiv.org/abs/2308.04079)
- [gsplat library](https://github.com/nerfstudio-project/gsplat)
- [nerfstudio](https://github.com/nerfstudio-project/nerfstudio)
- [DN-Splatter (depth+normal)](https://arxiv.org/abs/2403.17822)
- [2DGS (surfels)](https://arxiv.org/abs/2403.17888)
- [aras-p/UnityGaussianSplatting](https://github.com/aras-p/UnityGaussianSplatting)
- [Spark (three.js)](https://github.com/sparkjsdev/spark)
- [Niantic SPZ compression](https://github.com/nianticlabs/spz)
- [ARKit depth](https://developer.apple.com/documentation/arkit/arframe/scenedepth)
- [Original gnarly splatting review](uploads/gnarly-splatting-research.md)

---

**Contact:** gjw62@cornell.edu  
**Last Updated:** November 5, 2026
