using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Networking;

/// <summary>
/// Navigator client for the AWS publish API. List and package download use signed S3 URLs.
/// A Cognito ID token is sent when the player is signed in. Anonymous reads are allowed.
/// Downloads are staged before the cache pointer moves, so the last complete package stays usable offline.
/// The type name is unchanged so existing scenes keep their script reference.
/// </summary>
public sealed class FirebaseNavigationPackageRepository
{
    readonly AwsNavigatorConfig config;
    string idToken;
    string refreshToken;
    DateTime tokenExpiresAtUtc;

    public string UserId { get; private set; }
    public string Email { get; private set; }
    public bool IsAuthenticated => !string.IsNullOrEmpty(idToken);
    public bool HasSavedSession => FirebaseSessionStore.HasRefreshToken || !string.IsNullOrEmpty(refreshToken);

    public FirebaseNavigationPackageRepository(AwsNavigatorConfig config)
    {
        this.config = config ?? AwsNavigatorConfig.Load();
    }

    public Task SignInWithGoogleAsync() => SignInHostedAsync("Google");

    public Task SignInWithEmailAsync() => SignInHostedAsync(null);

    async Task SignInHostedAsync(string identityProvider)
    {
        var verifier = CognitoAuth.CodeVerifier();
        var state = CognitoAuth.CodeVerifier();
        var redirect = HostedRedirect();
        var authorize = CognitoAuth.AuthorizeUrl(
            config.cognitoDomain, config.clientId, redirect, CognitoAuth.CodeChallenge(verifier), state, identityProvider);
        var callback = await CognitoAuth.WaitForRedirect(authorize, redirect);
        var query = CognitoAuth.Query(callback);
        if (query.TryGetValue("error_description", out var description) && !string.IsNullOrEmpty(description))
            throw new FirebaseNavigationException(description);
        if (query.TryGetValue("error", out var oauthError) && !string.IsNullOrEmpty(oauthError))
            throw new FirebaseNavigationException(oauthError);
        if (!query.TryGetValue("state", out var returnedState) || returnedState != state
            || !query.TryGetValue("code", out var code) || string.IsNullOrEmpty(code))
            throw new FirebaseNavigationException("Google sign-in could not be completed. Try again.");
        var body = "grant_type=authorization_code"
            + "&client_id=" + UnityWebRequest.EscapeURL(config.clientId)
            + "&code=" + UnityWebRequest.EscapeURL(code)
            + "&redirect_uri=" + UnityWebRequest.EscapeURL(redirect)
            + "&code_verifier=" + UnityWebRequest.EscapeURL(verifier);
        ApplyTokenResponse(JsonUtility.FromJson<CognitoTokenResponse>(
            await PostFormAsync(CognitoAuth.TokenEndpoint(config.cognitoDomain), body, "Cognito sign-in")));
    }

    public async Task<bool> TryRestoreSessionAsync()
    {
        var savedRefreshToken = FirebaseSessionStore.LoadRefreshToken();
        if (string.IsNullOrEmpty(savedRefreshToken)) return false;

        refreshToken = savedRefreshToken;
        idToken = null;
        UserId = null;
        tokenExpiresAtUtc = DateTime.MinValue;
        try
        {
            await RefreshTokenAsync();
            return true;
        }
        catch
        {
            ForgetSavedSession();
            return false;
        }
    }

    public void ForgetSavedSession()
    {
        idToken = null;
        refreshToken = null;
        UserId = null;
        tokenExpiresAtUtc = DateTime.MinValue;
        FirebaseSessionStore.ClearRefreshToken();
    }

    public async Task<DownloadedNavigationPackage> DownloadActivePackageAsync(string buildingId, string zoneId)
    {
        ValidateIdentifier(buildingId, nameof(buildingId));
        ValidateIdentifier(zoneId, nameof(zoneId));
        var payload = JsonUtility.FromJson<PackageResponse>(await ApiGetAsync(
            $"/v1/buildings/{Uri.EscapeDataString(buildingId)}/package?zoneId={Uri.EscapeDataString(zoneId)}",
            "package download"));
        if (payload == null || string.IsNullOrEmpty(payload.versionId) || payload.zones == null || payload.zones.Length == 0)
            throw new FirebaseNavigationException($"Building '{buildingId}' has no downloadable zone '{zoneId}'.");
        var versionId = payload.versionId;
        ValidateIdentifier(versionId, "activeVersion");
        var zone = payload.zones[0];
        if (zone == null || zone.zoneId != zoneId)
            throw new FirebaseNavigationException($"Package response did not include zone '{zoneId}'.");

        var packageRoot = PackageRoot(buildingId, zoneId);
        Directory.CreateDirectory(packageRoot);
        var staging = Path.Combine(packageRoot, ".download-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            var buildingFile = Path.Combine(staging, "building.json");
            var scanFile = Path.Combine(staging, "scan.json");
            var scanFeaturesFile = Path.Combine(staging, "scan-features.json");
            var structureFile = Path.Combine(staging, "structure.usdz");
            var worldMapFile = Path.Combine(staging, $"worldmap-{zoneId}.bin");
            await DownloadSignedAsync(RequiredPackageFile(zone.files, "building.json").url, buildingFile, "building.json");
            await DownloadSignedAsync(RequiredPackageFile(zone.files, "scan.json").url, scanFile, "raw RoomPlan scan.json");
            await DownloadSignedAsync(RequiredPackageFile(zone.files, "scan-features.json").url, scanFeaturesFile, "normalized RoomPlan scan-features.json");
            await DownloadSignedAsync(RequiredPackageFile(zone.files, "structure.usdz").url, structureFile, "RoomPlan structure.usdz");
            await DownloadSignedAsync(RequiredPackageFile(zone.files, "worldmap.bin").url, worldMapFile, "ARWorldMap");
            ValidatePackageFiles(buildingFile, scanFile, scanFeaturesFile, structureFile, worldMapFile, zoneId);
            var connectionsFile = Path.Combine(staging, "zone-connections.json");
            await TryDownloadSignedAsync(FindPackageFile(payload.files, "zone-connections.json"), connectionsFile, "zone-connections.json");
            if (File.Exists(connectionsFile))
            {
                try { Pathfinding.ParseConnections(File.ReadAllText(connectionsFile)); }
                catch (Exception exception)
                {
                    File.Delete(connectionsFile);
                    Debug.Log($"[Gnarly] Ignoring unreadable zone connections: {exception.Message}");
                }
            }
            await TryDownloadSignedAsync(FindPackageFile(payload.files, "building-layout.json"), Path.Combine(staging, "building-layout.json"), "building-layout.json");
            var colorJson = Path.Combine(staging, SurfaceColors.JsonFileName);
            var colorAtlas = Path.Combine(staging, SurfaceColors.AtlasFileName);
            await TryDownloadSignedAsync(FindPackageFile(zone.files, SurfaceColors.JsonFileName), colorJson, SurfaceColors.JsonFileName);
            await TryDownloadSignedAsync(FindPackageFile(zone.files, SurfaceColors.AtlasFileName), colorAtlas, SurfaceColors.AtlasFileName);
            if (File.Exists(colorJson) && (SurfaceColors.Parse(File.ReadAllText(colorJson)) == null || !File.Exists(colorAtlas)))
            {
                File.Delete(colorJson);
                if (File.Exists(colorAtlas)) File.Delete(colorAtlas);
            }
            await TryDownloadSignedAsync(FindPackageFile(zone.files, "gaussian-splat.json"), Path.Combine(staging, "gaussian-splat.json"), "gaussian-splat.json");
            await TryDownloadSignedAsync(FindPackageFile(zone.files, "gaussian-splat.spz"), Path.Combine(staging, "gaussian-splat.spz"), "gaussian-splat.spz");
            await TryDownloadSignedAsync(FindPackageFile(zone.files, "gaussian-splat.ply"), Path.Combine(staging, "gaussian-splat.ply"), "gaussian-splat.ply");
            await TryDownloadSignedAsync(FindPackageFile(zone.files, "gaussian-splat.splat"), Path.Combine(staging, "gaussian-splat.splat"), "gaussian-splat.splat");
            await TryDownloadSignedAsync(FindPackageFile(zone.files, "textured-mesh.glb"), Path.Combine(staging, "textured-mesh.glb"), "textured-mesh.glb");
            File.WriteAllText(Path.Combine(staging, "package.json"), JsonUtility.ToJson(new CacheManifest
            {
                buildingId = buildingId,
                versionId = versionId,
                zoneId = zoneId,
                cachedAtUtc = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)
            }, true));

            var finalDirectory = Path.Combine(packageRoot, versionId);
            if (Directory.Exists(finalDirectory)) Directory.Delete(finalDirectory, true);
            Directory.Move(staging, finalDirectory);
            WriteAtomically(LatestPointerPath(buildingId, zoneId),
                JsonUtility.ToJson(new LatestPointer { versionId = versionId }));
            Debug.Log($"[Gnarly] Cached map package {buildingId}/{versionId}/{zoneId} at {finalDirectory}.");
            return new DownloadedNavigationPackage(buildingId, versionId, zoneId, finalDirectory, false);
        }
        catch
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            throw;
        }
    }

    public async Task<List<FirebaseScanChoice>> ListAvailableScansAsync()
    {
        var payload = JsonUtility.FromJson<LibraryResponse>(await ApiGetAsync("/v1/buildings", "scan library"));
        var result = new List<FirebaseScanChoice>();
        if (payload?.buildings == null) return result;
        foreach (var building in payload.buildings)
        {
            if (building == null || string.IsNullOrEmpty(building.id) || string.IsNullOrEmpty(building.activeVersion) || building.zones == null)
                continue;
            foreach (var zone in building.zones)
            {
                if (zone == null || string.IsNullOrEmpty(zone.id)) continue;
                result.Add(new FirebaseScanChoice(building.id, building.activeVersion, zone.id, building.name, zone.floorId, zone.name));
            }
        }
        return result;
    }

    public bool TryGetCachedPackage(string buildingId, string zoneId, out DownloadedNavigationPackage package)
    {
        package = null;
        try
        {
            ValidateIdentifier(buildingId, nameof(buildingId));
            ValidateIdentifier(zoneId, nameof(zoneId));
            var root = PackageRoot(buildingId, zoneId);
            if (!Directory.Exists(root)) return false;
            var candidates = new System.Collections.Generic.List<string>();
            var pointerPath = LatestPointerPath(buildingId, zoneId);
            if (File.Exists(pointerPath))
            {
                var pointer = JsonUtility.FromJson<LatestPointer>(File.ReadAllText(pointerPath));
                if (pointer != null && !string.IsNullOrEmpty(pointer.versionId))
                    candidates.Add(Path.Combine(root, pointer.versionId));
            }

            var directories = Directory.GetDirectories(root);
            Array.Sort(directories, (left, right) =>
                Directory.GetLastWriteTimeUtc(right).CompareTo(Directory.GetLastWriteTimeUtc(left)));
            foreach (var directory in directories)
                if (!Path.GetFileName(directory).StartsWith(".download-", StringComparison.Ordinal) && !candidates.Contains(directory))
                    candidates.Add(directory);
            foreach (var directory in candidates)
            {
                try
                {
                    if (TryReadCompleteCache(directory, buildingId, zoneId, out package)) return true;
                }
                catch (Exception exception)
                {
                    Debug.LogWarning($"[Gnarly] Ignoring incomplete cache at {directory}: {exception.Message}");
                }
            }
        }
        catch (Exception exception)
        {
            Debug.LogWarning($"[Gnarly] Could not inspect the map cache: {exception.Message}");
        }
        return false;
    }

    async Task AttachFreshTokenAsync()
    {
        if (string.IsNullOrEmpty(idToken) && string.IsNullOrEmpty(refreshToken)) return;
        if (!string.IsNullOrEmpty(idToken) && DateTime.UtcNow < tokenExpiresAtUtc.AddMinutes(-1)) return;
        if (string.IsNullOrEmpty(refreshToken))
        {
            idToken = null;
            return;
        }
        await RefreshTokenAsync();
    }

    async Task RefreshTokenAsync()
    {
        if (string.IsNullOrEmpty(refreshToken))
            throw new FirebaseNavigationException("The Cognito session expired. Sign in again.");
        var form = "grant_type=refresh_token&client_id=" + UnityWebRequest.EscapeURL(config.clientId)
            + "&refresh_token=" + UnityWebRequest.EscapeURL(refreshToken);
        ApplyTokenResponse(JsonUtility.FromJson<CognitoTokenResponse>(
            await PostFormAsync(CognitoAuth.TokenEndpoint(config.cognitoDomain), form, "Cognito session refresh")), keepRefresh: true);
    }

    void ApplyTokenResponse(CognitoTokenResponse response, bool keepRefresh = false)
    {
        if (response == null || string.IsNullOrEmpty(response.id_token))
        {
            var detail = response != null && !string.IsNullOrEmpty(response.error_description)
                ? response.error_description
                : "Cognito did not return an ID token.";
            throw new FirebaseNavigationException(detail);
        }
        idToken = response.id_token;
        if (!string.IsNullOrEmpty(response.refresh_token)) refreshToken = response.refresh_token;
        else if (!keepRefresh) { /* authorization-code responses include the refresh token */ }
        var claims = ReadIdClaims(idToken);
        if (!string.IsNullOrEmpty(claims.sub)) UserId = claims.sub;
        Email = claims.email ?? "";
        var lifetime = response.expires_in > 0 ? response.expires_in : 3600;
        tokenExpiresAtUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, lifetime));
        FirebaseSessionStore.SaveRefreshToken(refreshToken);
    }

    static IdClaims ReadIdClaims(string jwt)
    {
        try
        {
            var parts = jwt.Split('.');
            if (parts.Length < 2) return new IdClaims();
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            switch (payload.Length % 4)
            {
                case 2: payload += "=="; break;
                case 3: payload += "="; break;
            }
            return JsonUtility.FromJson<IdClaims>(Encoding.UTF8.GetString(Convert.FromBase64String(payload))) ?? new IdClaims();
        }
        catch
        {
            return new IdClaims();
        }
    }

    async Task<string> ApiGetAsync(string path, string operation)
    {
        try { await AttachFreshTokenAsync(); }
        catch (Exception exception)
        {
            Debug.LogWarning($"[Gnarly] Cognito session was dropped: {exception.Message}");
            ForgetSavedSession();
        }
        using var request = UnityWebRequest.Get(ApiBaseUrl() + path);
        if (!string.IsNullOrEmpty(idToken)) request.SetRequestHeader("Authorization", "Bearer " + idToken);
        return await SendForTextAsync(request, operation);
    }

    string ApiBaseUrl() => (string.IsNullOrWhiteSpace(config.apiBase) ? CognitoAuth.DefaultApiBase : config.apiBase).TrimEnd('/');

    string HostedRedirect()
    {
#if UNITY_IOS && !UNITY_EDITOR
        return string.IsNullOrWhiteSpace(config.deviceRedirectUri) ? CognitoAuth.DeviceRedirectUri : config.deviceRedirectUri;
#else
        return CognitoAuth.EditorRedirectUri;
#endif
    }

    static PackageFile FindPackageFile(PackageFile[] files, string name)
    {
        if (files == null) return null;
        foreach (var file in files)
            if (file != null && file.name == name && !string.IsNullOrEmpty(file.url)) return file;
        return null;
    }

    static PackageFile RequiredPackageFile(PackageFile[] files, string name)
    {
        var file = FindPackageFile(files, name);
        if (file == null) throw new FirebaseNavigationException($"The publish API did not return {name}.");
        return file;
    }

    async Task DownloadSignedAsync(string url, string destination, string label)
    {
        using var request = new UnityWebRequest(url, UnityWebRequest.kHttpVerbGET)
        {
            downloadHandler = new DownloadHandlerFile(destination, true)
        };
        await SendAsync(request, "Package download " + label);
    }

    async Task TryDownloadSignedAsync(PackageFile file, string destination, string label)
    {
        if (file == null) return;
        try { await DownloadSignedAsync(file.url, destination, label); }
        catch (Exception exception)
        {
            if (File.Exists(destination)) File.Delete(destination);
            Debug.Log($"[Gnarly] Optional {label} was not downloaded: {exception.Message}");
        }
    }

    static async Task<string> PostFormAsync(string url, string body, string operation)
    {
        using var request = new UnityWebRequest(url, UnityWebRequest.kHttpVerbPOST)
        {
            uploadHandler = new UploadHandlerRaw(Encoding.UTF8.GetBytes(body)),
            downloadHandler = new DownloadHandlerBuffer()
        };
        request.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded");
        return await SendForTextAsync(request, operation);
    }

    static async Task<string> SendForTextAsync(UnityWebRequest request, string operation)
    {
        if (request.downloadHandler == null) request.downloadHandler = new DownloadHandlerBuffer();
        await SendAsync(request, operation);
        return request.downloadHandler.text;
    }

    static async Task SendAsync(UnityWebRequest request, string operation)
    {
        var completion = new TaskCompletionSource<bool>();
        var asyncOperation = request.SendWebRequest();
        asyncOperation.completed += _ => completion.TrySetResult(true);
        await completion.Task;
        if (request.result == UnityWebRequest.Result.Success) return;

        var detail = request.downloadHandler is DownloadHandlerBuffer
            ? ExtractFirebaseError(request.downloadHandler.text)
            : null;
        if (string.IsNullOrEmpty(detail)) detail = request.error;
        throw new FirebaseNavigationException($"{operation} failed ({request.responseCode}): {detail}");
    }

    static string ExtractFirebaseError(string body)
    {
        if (string.IsNullOrEmpty(body)) return null;
        try
        {
            return JsonUtility.FromJson<FirebaseErrorEnvelope>(body)?.error?.message;
        }
        catch
        {
            return null;
        }
    }

    static bool TryReadCompleteCache(
        string directory,
        string expectedBuildingId,
        string expectedZoneId,
        out DownloadedNavigationPackage package)
    {
        package = null;
        var manifestPath = Path.Combine(directory, "package.json");
        if (!File.Exists(manifestPath)) return false;
        var manifest = JsonUtility.FromJson<CacheManifest>(File.ReadAllText(manifestPath));
        if (manifest == null || manifest.buildingId != expectedBuildingId || manifest.zoneId != expectedZoneId)
            return false;

        ValidateIdentifier(manifest.versionId, "cached versionId");
        ValidatePackageFiles(
            Path.Combine(directory, "building.json"),
            Path.Combine(directory, "scan.json"),
            Path.Combine(directory, "scan-features.json"),
            Path.Combine(directory, "structure.usdz"),
            Path.Combine(directory, $"worldmap-{expectedZoneId}.bin"),
            expectedZoneId);
        package = new DownloadedNavigationPackage(
            manifest.buildingId, manifest.versionId, manifest.zoneId, directory, true);
        return true;
    }

    static void ValidatePackageFiles(
        string buildingFile,
        string scanFile,
        string scanFeaturesFile,
        string structureFile,
        string worldMapFile,
        string expectedZoneId)
    {
        if (!File.Exists(buildingFile) || new FileInfo(buildingFile).Length == 0)
            throw new FirebaseNavigationException("Downloaded building.json is missing or empty.");
        if (!File.Exists(scanFile) || new FileInfo(scanFile).Length == 0)
            throw new FirebaseNavigationException("Downloaded raw RoomPlan scan.json is missing or empty.");
        if (!File.Exists(scanFeaturesFile) || new FileInfo(scanFeaturesFile).Length == 0)
            throw new FirebaseNavigationException("Downloaded normalized RoomPlan scan-features.json is missing or empty.");
        if (!File.Exists(structureFile) || new FileInfo(structureFile).Length == 0)
            throw new FirebaseNavigationException("Downloaded RoomPlan structure.usdz is missing or empty.");
        if (!File.Exists(worldMapFile) || new FileInfo(worldMapFile).Length == 0)
            throw new FirebaseNavigationException("Downloaded ARWorldMap is missing or empty.");

        var building = Pathfinding.ParseBuilding(File.ReadAllText(buildingFile));
        if (building.schemaVersion != 1)
            throw new FirebaseNavigationException($"Unsupported building.json schemaVersion {building.schemaVersion}.");
        if (building.zoneId != expectedZoneId)
            throw new FirebaseNavigationException(
                $"building.json zone '{building.zoneId}' does not match requested zone '{expectedZoneId}'.");
        if (building.nodes == null || building.edges == null)
            throw new FirebaseNavigationException("building.json must contain nodes and edges arrays.");

        var rawScan = File.ReadAllText(scanFile).TrimStart();
        if (!rawScan.StartsWith("{", StringComparison.Ordinal))
            throw new FirebaseNavigationException("Downloaded raw RoomPlan scan.json is not a JSON object.");

        var scan = Pathfinding.ParseScan(File.ReadAllText(scanFeaturesFile));
        if (scan.schemaVersion != 1)
            throw new FirebaseNavigationException($"Unsupported scan-features.json schemaVersion {scan.schemaVersion}.");
        if (scan.zoneId != expectedZoneId)
            throw new FirebaseNavigationException(
                $"scan-features.json zone '{scan.zoneId}' does not match requested zone '{expectedZoneId}'.");
    }

    static void ValidateIdentifier(string value, string field)
    {
        if (string.IsNullOrWhiteSpace(value) || value == "." || value == "..")
            throw new ArgumentException($"{field} is required.");
        foreach (var character in value)
            if (character == '/' || character == '\\' || char.IsControl(character))
                throw new ArgumentException($"{field} cannot contain '/', '\\', or control characters.");
    }

    public List<DownloadedNavigationPackage> ListCachedPackages()
    {
        var result = new List<DownloadedNavigationPackage>();
        var root = Path.Combine(Application.persistentDataPath, "navigation-cache");
        if (!Directory.Exists(root)) return result;
        foreach (var buildingPath in Directory.GetDirectories(root))
            foreach (var zonePath in Directory.GetDirectories(buildingPath))
                if (TryGetCachedPackage(Path.GetFileName(buildingPath), Path.GetFileName(zonePath), out var package))
                    result.Add(package);
        return result;
    }

    static string PackageRoot(string buildingId, string zoneId) =>
        Path.Combine(Application.persistentDataPath, "navigation-cache", buildingId, zoneId);

    static string LatestPointerPath(string buildingId, string zoneId) =>
        Path.Combine(PackageRoot(buildingId, zoneId), "latest.json");

    static void WriteAtomically(string path, string contents)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, contents);
        if (File.Exists(path)) File.Delete(path);
        File.Move(temporary, path);
    }

    [Serializable] sealed class CognitoTokenResponse
    {
        public string id_token;
        public string access_token;
        public string refresh_token;
        public int expires_in;
        public string error_description;
    }

    [Serializable] sealed class IdClaims
    {
        public string sub;
        public string email;
    }

    [Serializable] sealed class LibraryResponse { public LibraryBuilding[] buildings; }
    [Serializable] sealed class LibraryBuilding
    {
        public string id;
        public string name;
        public string activeVersion;
        public LibraryZone[] zones;
    }
    [Serializable] sealed class LibraryZone
    {
        public string id;
        public string name;
        public string floorId;
    }
    [Serializable] sealed class PackageResponse
    {
        public string buildingId;
        public string versionId;
        public PackageFile[] files;
        public PackageZone[] zones;
    }
    [Serializable] sealed class PackageZone
    {
        public string zoneId;
        public string name;
        public string floorId;
        public PackageFile[] files;
    }
    [Serializable] sealed class PackageFile
    {
        public string name;
        public string url;
        public bool required;
    }

    [Serializable] sealed class FirebaseErrorEnvelope
    {
        public FirebaseError error;
    }

    [Serializable] sealed class FirebaseError
    {
        public string message;
    }

    [Serializable] sealed class CacheManifest
    {
        public string buildingId;
        public string versionId;
        public string zoneId;
        public string cachedAtUtc;
    }

    [Serializable] sealed class LatestPointer
    {
        public string versionId;
    }
}

/// <summary>Publish API and Cognito settings. Defaults match the live AWS account. Override in Resources.</summary>
public sealed class AwsNavigatorConfig
{
    public string apiBase = CognitoAuth.DefaultApiBase;
    public string cognitoDomain = CognitoAuth.DefaultDomain;
    public string clientId = CognitoAuth.DefaultClientId;
    public string userPoolId = CognitoAuth.DefaultPoolId;
    public string deviceRedirectUri = CognitoAuth.DeviceRedirectUri;

    public static AwsNavigatorConfig Load()
    {
        var config = new AwsNavigatorConfig();
        Apply(config, Resources.Load<TextAsset>("gnarly-aws"));
        Apply(config, Resources.Load<TextAsset>("gnarly-api-base"));
        return config;
    }

    static void Apply(AwsNavigatorConfig config, TextAsset asset)
    {
        if (asset == null || string.IsNullOrEmpty(asset.text)) return;
        foreach (var raw in asset.text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
            var cut = line.IndexOf('=');
            if (cut > 0)
            {
                var key = line.Substring(0, cut).Trim();
                var value = line.Substring(cut + 1).Trim();
                if (value.Length == 0) continue;
                if (key == "apiBase") config.apiBase = value;
                else if (key == "cognitoDomain") config.cognitoDomain = value;
                else if (key == "cognitoClientId") config.clientId = value;
                else if (key == "cognitoUserPoolId") config.userPoolId = value;
                else if (key == "cognitoRedirectUri") config.deviceRedirectUri = value;
                continue;
            }
            if (line.StartsWith("https://", StringComparison.Ordinal) ||
                line.StartsWith("http://127.0.0.1", StringComparison.Ordinal) ||
                line.StartsWith("http://localhost", StringComparison.Ordinal))
                config.apiBase = line;
        }
    }
}

public sealed class DownloadedNavigationPackage
{
    public string BuildingId { get; }
    public string VersionId { get; }
    public string ZoneId { get; }
    public string DirectoryPath { get; }
    public bool IsOfflineCache { get; }

    public DownloadedNavigationPackage(
        string buildingId,
        string versionId,
        string zoneId,
        string directoryPath,
        bool isOfflineCache)
    {
        BuildingId = buildingId;
        VersionId = versionId;
        ZoneId = zoneId;
        DirectoryPath = directoryPath;
        IsOfflineCache = isOfflineCache;
    }
}

public sealed class FirebaseScanChoice
{
    public string BuildingId { get; }
    public string VersionId { get; }
    public string ZoneId { get; }
    public string BuildingName { get; }
    public string FloorId { get; }
    public string ZoneName { get; }
    public FirebaseScanChoice(string buildingId, string versionId, string zoneId,
        string buildingName = null, string floorId = null, string zoneName = null)
    {
        BuildingId = buildingId;
        VersionId = versionId;
        ZoneId = zoneId;
        BuildingName = buildingName;
        FloorId = floorId;
        ZoneName = ZoneLabels.Known(buildingId, zoneId) ?? zoneName;
    }
}

/// <summary>Display names fixed in the app for zones whose scans carry no useful name.</summary>
public static class ZoneLabels
{
    public static string Known(string buildingId, string zoneId) =>
        string.Equals(buildingId, "baker", StringComparison.OrdinalIgnoreCase) && zoneId == "1" ? "Entrance" : null;
}

public sealed class FirebaseNavigationException : Exception
{
    public FirebaseNavigationException(string message) : base(message) { }
}
