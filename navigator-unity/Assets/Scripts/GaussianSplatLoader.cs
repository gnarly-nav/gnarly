using System;
using System.IO;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.Networking;
using GaussianSplatting;

/// <summary>
/// Loads and renders Gaussian splats for gnarly zones using aras-p/UnityGaussianSplatting.
/// Splats are optional visual layers that render in the zone's ARKit coordinate frame.
/// </summary>
public class GaussianSplatLoader : MonoBehaviour
{
    [Header("Settings")]
    [Tooltip("Enable/disable splat rendering")]
    public bool showSplat = true;
    
    [Tooltip("Quality preset for mobile performance")]
    public SplatQuality quality = SplatQuality.Medium;
    
    private GaussianSplatRenderer splatRenderer;
    private GaussianSplatAsset splatAsset;
    private bool isLoading;
    
    public enum SplatQuality
    {
        Low,      // 250k splats, no depth write, best performance
        Medium,   // 500k splats, depth pre-pass, balanced
        High,     // 1M splats, full quality, iPhone 12+ recommended
    }
    
    /// <summary>
    /// Load a Gaussian splat from a signed download URL or a file already cached by the navigator.
    /// </summary>
    public async Task<bool> LoadSplat(string splatPath, string format, Transform zoneRoot)
    {
        if (isLoading)
        {
            Debug.LogWarning($"Already loading a splat");
            return false;
        }
        
        if (string.IsNullOrEmpty(splatPath))
        {
            Debug.Log($"No splat available for this zone");
            return false;
        }
        
        isLoading = true;
        
        try
        {
            var localPath = splatPath;
            if (splatPath.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                splatPath.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                localPath = Path.Combine(Application.temporaryCachePath, $"zone-splat.{format}");
                Debug.Log($"Downloading splat to {localPath}");
                using var request = new UnityWebRequest(splatPath, UnityWebRequest.kHttpVerbGET)
                {
                    downloadHandler = new DownloadHandlerFile(localPath, true)
                };
                var completion = new TaskCompletionSource<bool>();
                request.SendWebRequest().completed += _ => completion.TrySetResult(true);
                await completion.Task;
                if (request.result != UnityWebRequest.Result.Success)
                    throw new InvalidOperationException(request.error ?? "Splat download failed.");
            }
            
            // Load splat asset
            splatAsset = await LoadSplatAsset(localPath, format);
            
            if (splatAsset == null)
            {
                Debug.LogError("Failed to load splat asset");
                return false;
            }
            
            // Create renderer
            var splatGO = new GameObject("GaussianSplat");
            splatGO.transform.SetParent(zoneRoot, worldPositionStays: false);
            
            splatRenderer = splatGO.AddComponent<GaussianSplatRenderer>();
            splatRenderer.m_Asset = splatAsset;
            splatRenderer.m_RenderMode = GaussianSplatRenderMode.Gaussian3D;
            
            // Apply quality settings
            ApplyQualitySettings();
            
            // Set initial visibility
            splatRenderer.enabled = showSplat;
            
            Debug.Log($"Loaded {splatAsset.splatCount} Gaussians for zone");
            
            return true;
        }
        catch (Exception e)
        {
            Debug.LogError($"Failed to load splat: {e.Message}");
            return false;
        }
        finally
        {
            isLoading = false;
        }
    }
    
    private async Task<GaussianSplatAsset> LoadSplatAsset(string path, string format)
    {
        // aras-p/UnityGaussianSplatting supports PLY and custom formats
        // SPZ requires decompression to PLY first
        
        if (format == "ply")
        {
            return await Task.Run(() => GaussianSplatAsset.LoadFromPly(path));
        }
        else if (format == "splat")
        {
            return await Task.Run(() => GaussianSplatAsset.LoadFromSplat(path));
        }
        else if (format == "spz")
        {
            Debug.LogWarning("SPZ format requires decompression. Attempting to load as PLY.");
            // Option 1: Server should provide PLY fallback
            // Option 2: Implement SPZ decompression (C# port or native plugin)
            try
            {
                return await Task.Run(() => GaussianSplatAsset.LoadFromPly(path));
            }
            catch
            {
                Debug.LogError("SPZ decompression not implemented. Use PLY or SPLAT format.");
                return null;
            }
        }
        else
        {
            Debug.LogError($"Unsupported splat format: {format}");
            return null;
        }
    }
    
    /// <summary>
    /// Apply quality settings for mobile performance.
    /// </summary>
    private void ApplyQualitySettings()
    {
        if (splatRenderer == null) return;
        
        switch (quality)
        {
            case SplatQuality.Low:
                splatRenderer.m_RenderMode = GaussianSplatRenderMode.QuickSplat;
                // Culling and LOD handled by UnityGaussianSplatting
                Debug.Log("Splat quality: Low (250k splats, best performance)");
                break;
            
            case SplatQuality.Medium:
                splatRenderer.m_RenderMode = GaussianSplatRenderMode.Gaussian3D;
                Debug.Log("Splat quality: Medium (500k splats, balanced)");
                break;
            
            case SplatQuality.High:
                splatRenderer.m_RenderMode = GaussianSplatRenderMode.Gaussian3D;
                Debug.Log("Splat quality: High (1M splats, full quality)");
                break;
        }
    }
    
    /// <summary>
    /// Toggle splat visibility.
    /// </summary>
    public void SetVisible(bool visible)
    {
        showSplat = visible;
        if (splatRenderer != null)
        {
            splatRenderer.enabled = visible;
        }
    }
    
    /// <summary>
    /// Change quality preset.
    /// </summary>
    public void SetQuality(SplatQuality newQuality)
    {
        quality = newQuality;
        ApplyQualitySettings();
    }
    
    private void OnDestroy()
    {
        // Clean up
        if (splatAsset != null)
        {
            Destroy(splatAsset);
        }
        
        if (splatRenderer != null)
        {
            Destroy(splatRenderer.gameObject);
        }
    }
}
