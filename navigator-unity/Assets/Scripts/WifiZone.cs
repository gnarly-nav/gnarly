using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using UnityEngine;

/// <summary>
/// BSSID label for one scanned zone. The navigator uses it to choose a world map.
/// ARKit still produces the position after that map loads.
/// </summary>
public static class WifiZone
{
    public const string FileName = "wifi-zone.json";

    static Task<string> probe;

    /// <summary>Lowercase colon-separated MAC, or null when the text is not a BSSID.</summary>
    public static string NormalizeBssid(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var parts = raw.Trim().Split(':');
        if (parts.Length != 6) return null;
        var octets = new string[6];
        for (var i = 0; i < 6; i++)
        {
            if (parts[i].Length != 1 && parts[i].Length != 2) return null;
            if (!byte.TryParse(parts[i], System.Globalization.NumberStyles.AllowHexSpecifier, null, out var value))
                return null;
            octets[i] = value.ToString("x2");
        }
        return string.Join(":", octets);
    }

    public static string[] ReadBssids(string directory, string zoneId)
    {
        if (string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(zoneId)) return Array.Empty<string>();
        var path = Path.Combine(directory, FileName);
        if (!File.Exists(path)) return Array.Empty<string>();
        try
        {
            var document = JsonUtility.FromJson<WifiZoneDocument>(File.ReadAllText(path));
            if (document == null || document.schemaVersion != 1 || document.zoneId != zoneId || document.accessPoints == null)
                return Array.Empty<string>();
            var bssids = new List<string>();
            foreach (var point in document.accessPoints)
            {
                var bssid = NormalizeBssid(point?.bssid);
                if (bssid != null && !bssids.Contains(bssid)) bssids.Add(bssid);
            }
            return bssids.ToArray();
        }
        catch (Exception exception)
        {
            Debug.Log($"[Gnarly] Ignoring unreadable {FileName}: {exception.Message}");
            return Array.Empty<string>();
        }
    }

    public static int ClaimCount(IReadOnlyList<FirebaseScanChoice> scans, string bssid)
    {
        if (string.IsNullOrEmpty(bssid) || scans == null) return 0;
        var count = 0;
        for (var i = 0; i < scans.Count; i++)
            if (scans[i] != null && scans[i].Claims(bssid)) count++;
        return count;
    }

    /// <summary>The one zone that recorded this access point, or null when none or several did.</summary>
    public static FirebaseScanChoice UniqueClaim(IReadOnlyList<FirebaseScanChoice> scans, string bssid)
    {
        if (string.IsNullOrEmpty(bssid) || scans == null) return null;
        FirebaseScanChoice found = null;
        for (var i = 0; i < scans.Count; i++)
        {
            var scan = scans[i];
            if (scan == null || !scan.Claims(bssid)) continue;
            if (found != null) return null;
            found = scan;
        }
        return found;
    }

    /// <summary>BSSID of the joined Wi-Fi network, or null in the Editor and when iOS will not reveal it.</summary>
    public static Task<string> CurrentBssidAsync()
    {
        if (probe == null) probe = ProbeAsync();
        return probe;
    }

    static async Task<string> ProbeAsync()
    {
#if UNITY_IOS && !UNITY_EDITOR
        GnarlyWifiRequestCurrent();
        var started = Time.realtimeSinceStartup;
        var deadline = started + 3f;
        while (true)
        {
            var state = GnarlyWifiState();
            if (state == 2)
            {
                var buffer = new byte[18];
                var handle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                try
                {
                    var length = GnarlyWifiCopyBssid(handle.AddrOfPinnedObject(), buffer.Length);
                    if (length <= 0) return null;
                    return NormalizeBssid(System.Text.Encoding.UTF8.GetString(buffer, 0, length));
                }
                finally { handle.Free(); }
            }
            if (state == 3) return null;
            if (Time.realtimeSinceStartup >= deadline)
            {
                if (GnarlyWifiAwaitingAuthorization() == 0 || Time.realtimeSinceStartup >= started + 25f)
                    return null;
            }
            await Task.Delay(150);
        }
#else
        await Task.CompletedTask;
        return null;
#endif
    }

#if UNITY_IOS && !UNITY_EDITOR
    [DllImport("__Internal")]
    static extern void GnarlyWifiRequestCurrent();

    [DllImport("__Internal")]
    static extern int GnarlyWifiState();

    [DllImport("__Internal")]
    static extern int GnarlyWifiAwaitingAuthorization();

    [DllImport("__Internal")]
    static extern int GnarlyWifiCopyBssid(IntPtr buffer, int capacity);
#endif

    [Serializable]
    sealed class WifiZoneDocument
    {
        public int schemaVersion;
        public string zoneId;
        public WifiAccessPointRecord[] accessPoints;
    }

    [Serializable]
    sealed class WifiAccessPointRecord
    {
        public string bssid;
        public string ssid;
    }
}
