#if UNITY_IOS
using System.IO;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;

public static class AppleRoomModelPreviewPostprocessor
{
    const string AuthScheme = "gnarlynavigator";

    [PostProcessBuild(1000)]
    public static void AddQuickLookFramework(BuildTarget target, string buildPath)
    {
        if (target != BuildTarget.iOS) return;

        var projectPath = PBXProject.GetPBXProjectPath(buildPath);
        var project = new PBXProject();
        project.ReadFromFile(projectPath);
        var frameworkTarget = project.GetUnityFrameworkTargetGuid();
        project.AddFrameworkToProject(frameworkTarget, "RealityKit.framework", false);
        project.AddFrameworkToProject(frameworkTarget, "CoreHaptics.framework", false);
        project.AddFrameworkToProject(frameworkTarget, "AuthenticationServices.framework", false);
        project.AddFrameworkToProject(project.GetUnityMainTargetGuid(), "AuthenticationServices.framework", false);
        project.WriteToFile(projectPath);
        RegisterAuthScheme(buildPath);
    }

    static void RegisterAuthScheme(string buildPath)
    {
        var plistPath = Path.Combine(buildPath, "Info.plist");
        var plist = new PlistDocument();
        plist.ReadFromFile(plistPath);
        if (!plist.root.values.ContainsKey("CFBundleURLTypes"))
            plist.root.CreateArray("CFBundleURLTypes");
        var urlTypes = plist.root["CFBundleURLTypes"].AsArray();
        if (urlTypes == null || HasScheme(urlTypes, AuthScheme)) return;
        var entry = urlTypes.AddDict();
        entry.SetString("CFBundleURLName", "com.gnarly.navigator");
        entry.CreateArray("CFBundleURLSchemes").AddString(AuthScheme);
        plist.WriteToFile(plistPath);
    }

    static bool HasScheme(PlistElementArray urlTypes, string scheme)
    {
        foreach (var element in urlTypes.values)
        {
            var dict = element.AsDict();
            if (dict == null || !dict.values.ContainsKey("CFBundleURLSchemes")) continue;
            var schemes = dict["CFBundleURLSchemes"].AsArray();
            if (schemes == null) continue;
            foreach (var item in schemes.values)
                if (item.AsString() == scheme) return true;
        }
        return false;
    }
}
#endif
