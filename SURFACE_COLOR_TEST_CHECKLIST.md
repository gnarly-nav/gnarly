# Surface Color Quality Improvements - Device Test Checklist

This checklist verifies the surface color improvements work correctly on actual iPhone hardware.

## Pre-Test Setup

1. Build and install the updated mapper app on an iPhone with LiDAR (iPhone 12 Pro or later)
2. Have a test room ready (preferably with varied surfaces: walls, floors, objects)
3. Clear old scan data if testing with a previously scanned room

## Phase 1: Capture Verification

Test that the improved capture system works correctly.

### Frame Storage
- [ ] **HEIC files created**: Navigate to the temp directory and verify frames are `.heic` not `.jpg`
  - Expected: `frame-0000.heic`, `frame-0001.heic`, etc.
  - Check file sizes: should be ~200-500KB per frame (varies by complexity)

- [ ] **Depth files present**: Verify `.depth` files exist alongside images
  - Expected: `frame-0000.depth`, `frame-0001.depth`, etc.
  - File size should be ~256×192 × 4 bytes ≈ 196KB per file

- [ ] **Confidence files present**: Verify `.conf` files exist (NEW)
  - Expected: `frame-0000.conf`, `frame-0001.conf`, etc.
  - File size should be ~256×192 bytes ≈ 49KB per file

- [ ] **Frame count reasonable**: Capture for 2-3 minutes
  - Expected: 50-200 frames depending on room size and movement
  - Too few (<20): spacing gates may be too strict
  - Too many (>500): spacing gates may be too loose

### ARKit Integration
- [ ] **ARAnchors created**: Check Xcode console logs
  - Look for: Anchor creation messages (implementation detail)
  - Should see anchors being added throughout scan

- [ ] **Depth enabled**: In console, verify depth is available
  - Look for: "sceneDepth" or "smoothedSceneDepth" availability
  - On non-LiDAR devices: should gracefully fall back

### Sharpness Scoring
- [ ] **Sharpness computed**: Add debug logging to verify
  - Typical values: 500-5000 (higher = sharper)
  - Motion blur: <500
  - Sharp photos: 1000-3000+
  - Very sharp: 5000+

### Exposure Metadata
- [ ] **Exposure values captured**: Verify non-zero values
  - `exposureDuration`: typically 0.001-0.033 (1ms-33ms)
  - `exposureOffset`: typically -2.0 to +2.0 EV

## Phase 2: Bake Verification

Test that the improved baking process completes successfully.

### Bake Completion
- [ ] **No crashes**: Bake completes without memory errors
- [ ] **Reasonable time**: Should complete in 30s-2min for typical room
- [ ] **Progress updates**: UI shows incremental progress 0%-100%
- [ ] **Success message**: Reports number of colored faces

### Output Files
- [ ] **surface-colors.json created**: Check package directory
  - File should exist and be valid JSON
  - Size: typically 50-200KB depending on room complexity

- [ ] **surface-colors.jpg created**: Check package directory
  - Atlas file should exist
  - Size: typically 1-8MB depending on resolution
  - **Check resolution**: Should be 2048, 4096, or 8192 pixels
    - Small rooms: 2048×2048
    - Medium rooms: 4096×4096
    - Large rooms: 8192×8192 (NEW)

- [ ] **Metadata correct**: Open `surface-colors.json` and verify:
  - `schemaVersion: 1`
  - `atlasWidth` and `atlasHeight` match actual image
  - `texelMeters`: should be ~0.010-0.015 (was 0.015 minimum, now 0.010)
  - `usedLidarDepth: true` (if device has LiDAR)
  - `keyframeCount`: matches number of captured frames

### Bake Quality Metrics
- [ ] **Coverage reasonable**: Check logs for coverage percentage
  - Expected: 60-95% of texels seen
  - Low coverage (<40%): may need more/better photos

- [ ] **Face count**: Number of textured faces makes sense
  - Should be >80% of total faces for good scan

## Phase 3: Visual Quality (Web Viewer)

Load the scan in the web viewer and check visual improvements.

### Overall Quality
- [ ] **Noticeably sharper**: Textures should be crisp, not soft
  - Compare to old scans side-by-side if possible
  - Text on walls should be more readable
  - Texture details (brick, wood grain) should be visible

- [ ] **No ghosting**: No doubled/blurred edges
  - Check wall corners: should be clean single lines
  - Check objects: no "echo" or duplicate outlines
  - Window/door frames: sharp single boundaries

- [ ] **Correct alignment**: No obvious misalignment
  - Wall edges align with geometry
  - Floor patterns line up correctly
  - No offset between adjacent faces

- [ ] **Consistent lighting** ✨ NEW (PR #2)
  - No blotchy dark/bright patches across surfaces
  - Even illumination throughout the scan
  - Colors look balanced and natural

### Specific Issues Fixed

- [ ] **Clutter handling**: Shelves, pictures, cables less smeared
  - Before: smeared onto wall as blurry patches
  - After: either crisp or absent (not in box geometry)

- [ ] **Large walls**: High-res detail throughout
  - Check a large wall (>3m wide)
  - Should maintain quality across entire surface
  - No pixelation or blur in center

- [ ] **Seams**: Smooth transitions between faces ✨ IMPROVED (PR #2)
  - Should be noticeably better than before
  - Less visible color discontinuities
  - Gentle transitions, not harsh boundaries

### Color Accuracy
- [ ] **Colors look correct**: Not too dark, bright, or saturated
- [ ] **White balance reasonable**: Whites look white
- [ ] **Consistent lighting**: No dramatic patches (same as before)

## Phase 4: Unity Navigator

Test the navigator app with the new scan.

### Rendering Quality
- [ ] **No Z-fighting**: Overlay renders cleanly
  - Before: flickering/fighting between quad layers
  - After: stable rendering, no flicker

- [ ] **Depth sorting correct**: Quads occlude properly
  - Walk through scene in Unity
  - Nearer surfaces should properly hide farther ones
  - No "pop through" artifacts

- [ ] **Performance acceptable**: Frame rate is smooth
  - Should be 30+ FPS on iPhone 12 Pro
  - No stuttering when panning camera

### Overlay Behavior
- [ ] **Appears on correct surfaces**: Colors show on right geometry
- [ ] **Colors match web**: Same appearance as web viewer
- [ ] **Opacity correct**: Overlay blends properly with AR view
- [ ] **Stable in AR**: No jitter or misalignment as phone moves

## Phase 5: Edge Cases

Test boundary conditions and fallbacks.

### Device Variations
- [ ] **Non-LiDAR device**: Test on iPhone without LiDAR (e.g., iPhone 11)
  - Should fall back to geometry-based occlusion
  - `usedLidarDepth` should be `false`
  - Still produces reasonable results

- [ ] **Poor lighting**: Test in dim room
  - Should capture but with higher ISO/longer exposure
  - Quality may be lower but no crashes

### Room Variations
- [ ] **Small room** (2m × 2m):
  - Should complete quickly
  - Atlas should be 2048×2048 or 4096×4096

- [ ] **Large room** (10m × 10m):
  - Should complete without memory errors
  - Atlas may reach 8192×8192
  - Total texels should be <4M

- [ ] **Complex geometry**:
  - Room with many objects, stairs, windows
  - Should handle without crashes
  - Coverage may be lower but acceptable

### Failure Cases
- [ ] **No keyframes captured**: Start/stop scan immediately
  - Should handle gracefully (no crash)
  - May produce no surface colors (expected)

- [ ] **Corrupt depth data**: Simulate by deleting .depth files
  - Should fall back to geometry occlusion
  - Not crash during bake

## Phase 6: Regression Testing

Verify existing functionality still works.

### Backward Compatibility
- [ ] **Old scans load**: Previous surface-colors.json files work
  - Load an old scan in web viewer
  - Should display correctly
  - May look lower quality (expected)

- [ ] **Multiple zones**: Building with multiple scanned zones
  - Each zone gets its own improved surface colors
  - Zones align correctly in building view

### Other Features
- [ ] **Graph editing**: Waypoint editing still works
- [ ] **Route planning**: Routes display correctly over colored surfaces
- [ ] **Export**: Package export includes surface-colors files
- [ ] **Upload**: Firebase upload succeeds with new files

## Known Limitations

These are expected and documented:

- ⚠️ **Exposure normalization**: Not yet applied (metadata captured only)
- ⚠️ **Seam leveling**: Not implemented (future work)
- ⚠️ **Blotchy lighting**: May still occur (same as before)
- ⚠️ **Non-planar surfaces**: Curves/uneven walls still approximate as flat

## Rollback Plan

If major issues are found:

1. Git revert the commit
2. Rebuild and test with previous version
3. Document specific failure case
4. Fix issue in development branch
5. Re-test with this checklist

## Sign-Off

When all critical items pass, the feature is ready for production.

**Tester**: _______________  
**Date**: _______________  
**Device**: _______________  
**iOS Version**: _______________  

**Result**: ☐ Pass  ☐ Fail (see notes)

**Notes**:
