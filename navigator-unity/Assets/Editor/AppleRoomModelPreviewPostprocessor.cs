#if UNITY_IOS
using System.IO;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;

public static class AppleRoomModelPreviewPostprocessor
{
    const string LocationUsage = "Gnarly uses your location to read the building Wi-Fi network and open the right floor. The camera still finds your exact position.";

    [PostProcessBuild(1000)]
    public static void AddQuickLookFramework(BuildTarget target, string buildPath)
    {
        if (target != BuildTarget.iOS) return;

        var projectPath = PBXProject.GetPBXProjectPath(buildPath);
        var project = new PBXProject();
        project.ReadFromFile(projectPath);
        var mainTarget = project.GetUnityMainTargetGuid();
        var frameworkTarget = project.GetUnityFrameworkTargetGuid();
        project.AddFrameworkToProject(frameworkTarget, "RealityKit.framework", false);
        project.AddFrameworkToProject(frameworkTarget, "CoreHaptics.framework", false);
        project.AddFrameworkToProject(frameworkTarget, "CoreLocation.framework", false);
        project.AddFrameworkToProject(frameworkTarget, "NetworkExtension.framework", false);
        project.WriteToFile(projectPath);

        var capability = new ProjectCapabilityManager(projectPath, "Gnarly.entitlements", "Unity-iPhone", mainTarget);
        capability.AddAccessWiFiInformation();
        capability.WriteToFile();

        var plistPath = Path.Combine(buildPath, "Info.plist");
        var plist = new PlistDocument();
        plist.ReadFromFile(plistPath);
        plist.root.SetString("NSLocationWhenInUseUsageDescription", LocationUsage);
        var purposes = plist.root.values.ContainsKey("NSLocationTemporaryUsageDescriptionDictionary")
            ? plist.root["NSLocationTemporaryUsageDescriptionDictionary"].AsDict()
            : plist.root.CreateDict("NSLocationTemporaryUsageDescriptionDictionary");
        purposes.SetString("WifiZone", "Precise location lets Gnarly read the building Wi-Fi network so it can open the right floor.");
        plist.WriteToFile(plistPath);
    }
}
#endif
