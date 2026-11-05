using System;
using System.IO;
using UnityEngine;

/// <summary>
/// Textured real-geometry mesh baked by the server-side texturing worker from ARKit scene reconstruction
/// and captured keyframes (textured-mesh.json + textured-mesh.glb). This provides photoreal visuals
/// complementing RoomPlan's idealized box-based navigation geometry.
/// 
/// IMPORTANT: Requires a GLB/GLTF importer plugin for Unity (e.g., GLTFUtility, UnityGLTF, or glTFast).
/// This script assumes GLTFUtility is available. Install it from the Unity Asset Store or GitHub:
/// https://github.com/Siccity/GLTFUtility
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

            // Load the GLB using GLTFUtility (or another GLTF importer).
            // If GLTFUtility is not available, this will fail at runtime and return null.
            try
            {
                #if UNITY_EDITOR || !UNITY_WEBGL
                // GLTFUtility.Importer.LoadFromFile is synchronous and works in editor/standalone.
                // For WebGL or async loading, use GLTFUtility.Importer.LoadFromFileAsync.
                var importer = new Siccity.GLTFUtility.Importer();
                result.meshObject = importer.LoadFromFile(glbPath);
                
                if (result.meshObject != null)
                {
                    result.meshObject.name = $"TexturedMesh-{document.zoneId}";
                    // The mesh is in ARKit world coordinates, matching the zone's coordinate system.
                    // No transform adjustment needed if the zone's parent is already in ARKit coords.
                    Debug.Log($"[Gnarly] Loaded textured mesh: {document.meshTriangleCount} triangles, " +
                             $"{document.keyframeCount} keyframes, {document.texturingMethod}");
                }
                else
                {
                    Debug.LogWarning($"[Gnarly] GLB import returned null for {glbPath}");
                    return null;
                }
                #else
                Debug.LogWarning("[Gnarly] Synchronous GLB loading not supported on WebGL. Use async loader or preload.");
                return null;
                #endif
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[Gnarly] Failed to load GLB (is GLTFUtility installed?): {e.Message}");
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
