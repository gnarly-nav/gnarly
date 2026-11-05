using System;
using System.IO;
using UnityEngine;

/// <summary>
/// Textured real-geometry mesh baked by the server-side texturing worker from ARKit scene reconstruction
/// and captured keyframes (textured-mesh.json + textured-mesh.glb). This provides photoreal visuals
/// complementing RoomPlan's idealized box-based navigation geometry.
/// 
/// Uses glTFast (Unity's official package) for GLB loading. The package is included in Packages/manifest.json
/// as com.atteneder.gltfast@6.9.1, which is Unity 6 compatible.
/// </summary>
public sealed class TexturedMesh
{
    public const string JsonFileName = "textured-mesh.json";
    public const string MeshFileName = "textured-mesh.glb";

    [Serializable]
    public class Document
    {
        public int schemaVersion;
        public string zoneId;
        public string coordinateSystem;
        public string mesh;
        public string capturedAt;
        public int keyframeCount;
        public int meshTriangleCount;
        public string textureFormat;
        public int textureResolution;
        public string texturingMethod;
        public bool usedDepthOcclusion;
    }

    public Document document;
    public GameObject meshObject;

    public static Document Parse(string json)
    {
        var document = JsonUtility.FromJson<Document>(json);
        return document?.mesh == null ? null : document;
    }

    /// <summary>Loads the optional textured mesh from a cached zone package; null when absent or unreadable.</summary>
    public static TexturedMesh Load(string directory)
    {
        try
        {
            var jsonPath = Path.Combine(directory, JsonFileName);
            if (!File.Exists(jsonPath)) return null;
            var document = Parse(File.ReadAllText(jsonPath));
            if (document == null) return null;

            var glbPath = Path.Combine(directory, document.mesh);
            if (!File.Exists(glbPath))
            {
                Debug.LogWarning($"[Gnarly] Textured mesh metadata found but GLB file missing: {glbPath}");
                return null;
            }

            var result = new TexturedMesh { document = document };

            // Load the GLB using glTFast.
            try
            {
                // glTFast supports both synchronous and async loading.
                // For simplicity, we use the synchronous API here. For better performance,
                // consider using GltfImport.LoadAsync in production.
                var gltf = new GLTFast.GltfImport();
                var success = gltf.Load(glbPath);
                
                if (success)
                {
                    result.meshObject = new GameObject($"TexturedMesh-{document.zoneId}");
                    var instantiator = new GLTFast.GameObjectInstantiator(gltf, result.meshObject.transform);
                    success = gltf.InstantiateMainScene(instantiator);
                    
                    if (success && result.meshObject != null)
                    {
                        // The mesh is in ARKit world coordinates, matching the zone's coordinate system.
                        // No transform adjustment needed if the zone's parent is already in ARKit coords.
                        Debug.Log($"[Gnarly] Loaded textured mesh: {document.meshTriangleCount} triangles, " +
                                 $"{document.keyframeCount} keyframes, {document.texturingMethod}");
                    }
                    else
                    {
                        Debug.LogWarning($"[Gnarly] glTFast instantiation failed for {glbPath}");
                        if (result.meshObject != null) UnityEngine.Object.Destroy(result.meshObject);
                        return null;
                    }
                }
                else
                {
                    Debug.LogWarning($"[Gnarly] glTFast failed to load {glbPath}");
                    return null;
                }
                
                gltf.Dispose();
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[Gnarly] Failed to load GLB with glTFast: {e.Message}");
                return null;
            }

            return result;
        }
        catch (Exception exception)
        {
            Debug.LogWarning($"[Gnarly] Ignoring unreadable textured mesh in {directory}: {exception.Message}");
            return null;
        }
    }

    public void Dispose()
    {
        if (meshObject != null)
        {
            UnityEngine.Object.Destroy(meshObject);
            meshObject = null;
        }
    }
}
