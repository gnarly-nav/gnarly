# Unity Gaussian Splat Rendering

Integration guide for rendering Gaussian splats in the gnarly Unity navigator using aras-p/UnityGaussianSplatting.

## Overview

Gaussian splats provide photo-realistic visuals as an **optional layer** in the navigator. They:
- Render alongside (or instead of) surface-color textures
- Are toggleable by the user
- Fall back to RoomPlan boxes when unavailable
- Remain visual-only; RoomPlan boxes stay the navigation geometry

## Integration Approach

### 1. Dependencies

Add the [UnityGaussianSplatting](https://github.com/aras-p/UnityGaussianSplatting) package to the navigator:

```text
Unity Package Manager → Add package from git URL
https://github.com/aras-p/UnityGaussianSplatting.git
```

**Requirements:**
- Unity 6+ (current navigator version)
- Compute shader support (all ARKit-capable iOS devices)
- URP or Built-in render pipeline

### 2. Splat Asset Structure

Splats are stored per-zone in Firebase Storage alongside other zone files:

```text
buildings/{buildingId}/{versionId}/zones/{zoneId}/
  gaussian-splat.json    # Metadata (schema, bounds, config)
  gaussian-splat.spz     # Compressed splat data (preferred)
  gaussian-splat.ply     # Or standard PLY format
  gaussian-splat.splat   # Or antimatter15 format
```

The `ZoneData` class already handles surface colors; extend it for splats:

```csharp
public class ZoneData
{
    // Existing fields
    public string SurfaceColorsPath;
    public string SurfaceColorAtlasPath;
    
    // New fields for splats
    public string GaussianSplatPath;
    public string GaussianSplatDataPath;
    public GaussianSplatMetadata SplatMetadata;
}

[Serializable]
public class GaussianSplatMetadata
{
    public string format;
    public int splatCount;
    public Bounds bounds;
}
```

### 3. Loading Splats

Add a `GaussianSplatLoader` component parallel to `SurfaceColors.cs`:

```csharp
using UnityEngine;
using Firebase.Storage;
using GaussianSplatting;

public class GaussianSplatLoader : MonoBehaviour
{
    private GaussianSplatRenderer splatRenderer;
    private bool isLoading;
    
    public async Task<GameObject> LoadSplat(ZoneData zone)
    {
        if (string.IsNullOrEmpty(zone.GaussianSplatDataPath))
        {
            Debug.Log($"No splat available for zone {zone.Id}");
            return null;
        }
        
        isLoading = true;
        
        try
        {
            // Download splat data
            var storage = FirebaseStorage.DefaultInstance;
            var reference = storage.GetReference(zone.GaussianSplatDataPath);
            var localPath = Path.Combine(Application.temporaryCachePath, $"{zone.Id}-splat.{zone.SplatMetadata.format}");
            
            await reference.GetFileAsync(localPath);
            
            // Create splat GameObject
            var splatGO = new GameObject($"GaussianSplat-{zone.Id}");
            splatRenderer = splatGO.AddComponent<GaussianSplatRenderer>();
            
            // Load splat asset
            var asset = await LoadSplatAsset(localPath, zone.SplatMetadata.format);
            splatRenderer.SetSplatAsset(asset);
            
            // Apply ARKit transform to match zone coordinate system
            splatGO.transform.SetParent(transform, worldPositionStays: false);
            
            Debug.Log($"Loaded {zone.SplatMetadata.splatCount} splats for zone {zone.Id}");
            
            return splatGO;
        }
        catch (Exception e)
        {
            Debug.LogError($"Failed to load splat for zone {zone.Id}: {e.Message}");
            return null;
        }
        finally
        {
            isLoading = false;
        }
    }
    
    private async Task<GaussianSplatAsset> LoadSplatAsset(string path, string format)
    {
        // aras-p/UnityGaussianSplatting supports PLY and custom formats
        // SPZ requires conversion or custom loader
        if (format == "ply")
        {
            return await GaussianSplatAsset.LoadFromPly(path);
        }
        else if (format == "splat")
        {
            return await GaussianSplatAsset.LoadFromSplat(path);
        }
        else if (format == "spz")
        {
            // Option 1: Convert SPZ to PLY on server during training
            // Option 2: Implement SPZ loader (decompress to PLY format in memory)
            throw new NotImplementedException("SPZ format requires custom loader or server-side conversion");
        }
        else
        {
            throw new ArgumentException($"Unsupported splat format: {format}");
        }
    }
    
    public void SetVisible(bool visible)
    {
        if (splatRenderer != null)
        {
            splatRenderer.enabled = visible;
        }
    }
    
    private void OnDestroy()
    {
        // Clean up cached files
        if (splatRenderer?.Asset != null)
        {
            Destroy(splatRenderer.Asset);
        }
    }
}
```

### 4. Integration with IndoorMapOverlay

Update `IndoorMapOverlay.cs` to manage splat visibility alongside surface colors:

```csharp
public class IndoorMapOverlay : MonoBehaviour
{
    // Existing
    private Dictionary<string, GameObject> surfaceColorOverlays = new();
    
    // New
    private Dictionary<string, GameObject> splatOverlays = new();
    private bool showSplats = true; // User preference
    
    public async Task LoadZone(ZoneData zone)
    {
        // Existing surface color loading
        if (!string.IsNullOrEmpty(zone.SurfaceColorsPath))
        {
            var colorOverlay = await LoadSurfaceColors(zone);
            surfaceColorOverlays[zone.Id] = colorOverlay;
        }
        
        // New splat loading (optional, user-controlled)
        if (showSplats && !string.IsNullOrEmpty(zone.GaussianSplatDataPath))
        {
            var loader = gameObject.AddComponent<GaussianSplatLoader>();
            var splatOverlay = await loader.LoadSplat(zone);
            if (splatOverlay != null)
            {
                splatOverlays[zone.Id] = splatOverlay;
                
                // Hide surface colors when splats are visible (user preference)
                if (surfaceColorOverlays.TryGetValue(zone.Id, out var colors))
                {
                    colors.SetActive(!showSplats);
                }
            }
        }
    }
    
    public void ToggleSplats(bool enabled)
    {
        showSplats = enabled;
        
        foreach (var kvp in splatOverlays)
        {
            kvp.Value.SetActive(enabled);
            
            // Toggle surface colors as fallback
            if (surfaceColorOverlays.TryGetValue(kvp.Key, out var colors))
            {
                colors.SetActive(!enabled);
            }
        }
    }
}
```

### 5. Mobile Performance Considerations

**Target:** ~500k–1M splats per zone on iPhone 12+ / ARKit-capable devices.

**Optimizations:**

1. **LOD System**
   - Load high-quality splats when stationary
   - Reduce splat count while moving (cull by distance/view frustum)
   - aras-p/UnityGaussianSplatting includes built-in LOD

2. **Quality Settings**
   ```csharp
   public enum SplatQuality
   {
       Low,    // 250k splats, disable depth write
       Medium, // 500k splats, depth pre-pass
       High,   // 1M splats, full quality
   }
   
   public void ApplySplatQuality(SplatQuality quality)
   {
       foreach (var splat in splatOverlays.Values)
       {
           var renderer = splat.GetComponent<GaussianSplatRenderer>();
           switch (quality)
           {
               case SplatQuality.Low:
                   renderer.MaxSplats = 250_000;
                   renderer.UseDepthWrite = false;
                   break;
               case SplatQuality.Medium:
                   renderer.MaxSplats = 500_000;
                   renderer.UseDepthWrite = true;
                   break;
               case SplatQuality.High:
                   renderer.MaxSplats = 1_000_000;
                   renderer.UseDepthWrite = true;
                   break;
           }
       }
   }
   ```

3. **Lazy Loading**
   - Only load splats for the current zone
   - Preload adjacent zones in background
   - Unload splats when transitioning zones

4. **Render Order**
   - Render splats **after** RoomPlan boxes (depth write)
   - Use depth pre-pass to avoid overdraw
   - Splats are visual only; boxes remain clickable for navigation

### 6. Format Support

| Format | Size | Mobile | Server | Notes |
|--------|------|--------|--------|-------|
| **SPZ** (Niantic) | Smallest (~5-15 MB) | ✅ Best | Requires custom loader | Recommended for production |
| **PLY** | Large (~50-100 MB) | ⚠️ Slow | ✅ Native | Standard format, slow to parse |
| **SPLAT** (antimatter15) | Medium (~20-40 MB) | ✅ Good | ✅ Simple | Good fallback |

**Recommendation:** Train to PLY, compress server-side to SPZ, serve SPZ. Optionally provide PLY as fallback.

### 7. User Controls

Add UI toggles in the navigator settings:

```csharp
public class NavigatorSettings : MonoBehaviour
{
    public Toggle splatToggle;
    public Dropdown qualityDropdown;
    
    void Start()
    {
        // Load preferences
        bool showSplats = PlayerPrefs.GetInt("ShowSplats", 1) == 1;
        int quality = PlayerPrefs.GetInt("SplatQuality", 1); // Medium
        
        splatToggle.isOn = showSplats;
        qualityDropdown.value = quality;
        
        splatToggle.onValueChanged.AddListener(OnSplatToggle);
        qualityDropdown.onValueChanged.AddListener(OnQualityChanged);
    }
    
    void OnSplatToggle(bool enabled)
    {
        PlayerPrefs.SetInt("ShowSplats", enabled ? 1 : 0);
        FindObjectOfType<IndoorMapOverlay>()?.ToggleSplats(enabled);
    }
    
    void OnQualityChanged(int index)
    {
        PlayerPrefs.SetInt("SplatQuality", index);
        FindObjectOfType<IndoorMapOverlay>()?.ApplySplatQuality((SplatQuality)index);
    }
}
```

## Testing Checklist

**Without GPU/device:**
- [x] Schema and data model additions compile
- [x] Loader placeholder logic is correct
- [ ] Firebase Storage paths match API conventions

**With iOS device:**
- [ ] Splat loads and renders in ARKit coordinate frame
- [ ] Splat aligns with RoomPlan boxes (same origin/orientation)
- [ ] Toggling splats shows/hides correctly
- [ ] Surface colors and splats don't Z-fight
- [ ] Frame rate ≥30 FPS with 500k splats on iPhone 12
- [ ] Memory usage <500 MB with splats loaded
- [ ] Transitioning zones unloads previous splats
- [ ] Splats render correctly after app backgrounding

**Edge cases:**
- [ ] Zone without splat falls back to surface colors
- [ ] Zone without surface colors or splat shows RoomPlan boxes only
- [ ] Invalid/corrupt splat file fails gracefully
- [ ] Network failure during download shows error, doesn't block navigation

## Future Enhancements

1. **Streaming:** Load splat tiles progressively as user moves
2. **Compression:** Implement SPZ decompression in Unity (C# port or native plugin)
3. **Editing:** Allow splats to be clipped/masked by RoomPlan geometry for better integration
4. **AR Overlay:** Render splats in AR passthrough mode as a "photo view"
5. **Training Feedback:** Show coverage heatmap in mapper during capture

## References

- aras-p/UnityGaussianSplatting: https://github.com/aras-p/UnityGaussianSplatting
- Niantic SPZ compression: https://github.com/nianticlabs/spz
- 3D Gaussian Splatting paper: https://arxiv.org/abs/2308.04079
- DN-Splatter (depth+normal): https://arxiv.org/abs/2403.17822
- Unity AR Foundation: https://docs.unity3d.com/Packages/com.unity.xr.arfoundation@6.0/

## Notes

- This document describes the **design** and integration points. Actual Unity implementation requires device testing.
- The web editor already supports splat rendering via three.js (see `web/src/Viewer.tsx` — integration pending).
- RoomPlan boxes **always** remain the source of truth for navigation; splats are decorative only.
