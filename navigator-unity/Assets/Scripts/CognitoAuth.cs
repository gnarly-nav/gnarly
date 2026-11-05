using System;
using System.Collections.Generic;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.Networking;

/// <summary>
/// Cognito hosted UI (PKCE) for Google sign-in. Email and password use CognitoSrp.
/// iOS uses the website's https redirect. The Editor uses the registered localhost redirect.
/// </summary>
public static class CognitoAuth
{
    public const string DefaultDomain = "gnarly-naijei.auth.us-east-1.amazoncognito.com";
    public const string DefaultClientId = "1osnrt38iuqvf5laum1tnj1hdn";
    public const string DefaultPoolId = "us-east-1_pQIUmVbPJ";
    public const string DefaultApiBase = "https://m7sgp6qsjkimymyrwa6bilxqzq0acbhx.lambda-url.us-east-1.on.aws";
    public const string DeviceRedirectUri = "https://naijei.com/gnarly/";
    public const string EditorRedirectUri = "http://localhost:5173/";

    public static string RedirectUri()
    {
#if UNITY_IOS && !UNITY_EDITOR
        return DeviceRedirectUri;
#else
        return EditorRedirectUri;
#endif
    }

    public static string CodeVerifier()
    {
        var bytes = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        return Base64Url(bytes);
    }

    public static string CodeChallenge(string verifier)
    {
        using (var sha = SHA256.Create())
            return Base64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
    }

    public static string AuthorizeUrl(string domain, string clientId, string redirectUri, string challenge, string state, string identityProvider)
    {
        var url = "https://" + Host(domain) + "/oauth2/authorize?response_type=code"
            + "&client_id=" + UnityWebRequest.EscapeURL(clientId)
            + "&redirect_uri=" + UnityWebRequest.EscapeURL(redirectUri)
            + "&scope=" + UnityWebRequest.EscapeURL("openid email")
            + "&code_challenge=" + UnityWebRequest.EscapeURL(challenge)
            + "&code_challenge_method=S256"
            + "&state=" + UnityWebRequest.EscapeURL(state);
        if (!string.IsNullOrEmpty(identityProvider))
            url += "&identity_provider=" + UnityWebRequest.EscapeURL(identityProvider);
        return url;
    }

    public static string TokenEndpoint(string domain) => "https://" + Host(domain) + "/oauth2/token";

    public static string Host(string domain)
    {
        var host = (domain ?? "").Trim();
        if (host.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) host = host.Substring("https://".Length);
        if (host.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) host = host.Substring("http://".Length);
        return host.Trim().TrimEnd('/');
    }

    public static async Task<string> WaitForRedirect(string authorizeUrl, string redirectUri)
    {
#if UNITY_IOS && !UNITY_EDITOR
        return await WaitNative(authorizeUrl, redirectUri);
#elif UNITY_EDITOR
        return await WaitLoopback(authorizeUrl, redirectUri);
#else
        await Task.CompletedTask;
        throw new InvalidOperationException("Google sign-in is available in the Unity Editor and on iOS.");
#endif
    }

#if UNITY_IOS && !UNITY_EDITOR
    [System.Runtime.InteropServices.DllImport("__Internal")]
    static extern void GnarlyCognitoBegin(string authorizeUrl, string redirectUri);
    [System.Runtime.InteropServices.DllImport("__Internal")]
    static extern System.IntPtr GnarlyCognitoPoll();
    [System.Runtime.InteropServices.DllImport("__Internal")]
    static extern void GnarlyCognitoFree(System.IntPtr value);

    static async Task<string> WaitNative(string authorizeUrl, string redirectUri)
    {
        GnarlyCognitoBegin(authorizeUrl, redirectUri);
        for (var i = 0; i < 720; i++)
        {
            await Task.Delay(250);
            var pointer = GnarlyCognitoPoll();
            if (pointer == System.IntPtr.Zero) continue;
            string value;
            try { value = System.Runtime.InteropServices.Marshal.PtrToStringAnsi(pointer); }
            finally { GnarlyCognitoFree(pointer); }
            if (string.IsNullOrEmpty(value)) continue;
            if (value.StartsWith("ok\n", StringComparison.Ordinal)) return value.Substring(3);
            throw new InvalidOperationException(value.StartsWith("err\n", StringComparison.Ordinal) ? value.Substring(4) : value);
        }
        throw new TimeoutException("Sign-in timed out.");
    }
#endif

#if UNITY_EDITOR
    static async Task<string> WaitLoopback(string authorizeUrl, string redirectUri)
    {
        var listener = new HttpListener();
        listener.Prefixes.Add(redirectUri);
        try { listener.Start(); }
        catch (HttpListenerException)
        {
            throw new InvalidOperationException("Port 5173 is in use, often by the website. Stop that process, then sign in again.");
        }
        using (listener)
        {
            Application.OpenURL(authorizeUrl);
            var contextTask = Task.Run(() => listener.GetContext());
            var finished = await Task.WhenAny(contextTask, Task.Delay(TimeSpan.FromMinutes(3)));
            if (finished != contextTask)
            {
                listener.Stop();
                throw new TimeoutException("Sign-in timed out.");
            }
            var context = contextTask.Result;
            var callback = context.Request.Url?.AbsoluteUri ?? "";
            var html = Encoding.UTF8.GetBytes("<!doctype html><title>Gnarly</title><p>Signed in. You can close this window and return to the navigator.</p>");
            context.Response.ContentType = "text/html; charset=utf-8";
            context.Response.ContentLength64 = html.Length;
            await context.Response.OutputStream.WriteAsync(html, 0, html.Length);
            context.Response.OutputStream.Close();
            if (string.IsNullOrEmpty(callback)) throw new InvalidOperationException("Google sign-in did not return to the app.");
            return callback;
        }
    }
#endif

    public static Dictionary<string, string> Query(string url)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var query = new Uri(url).Query;
        if (query.StartsWith("?", StringComparison.Ordinal)) query = query.Substring(1);
        foreach (var pair in query.Split('&'))
        {
            if (pair.Length == 0) continue;
            var cut = pair.IndexOf('=');
            var key = UnityWebRequest.UnEscapeURL(cut < 0 ? pair : pair.Substring(0, cut));
            var value = cut < 0 ? "" : UnityWebRequest.UnEscapeURL(pair.Substring(cut + 1));
            result[key] = value;
        }
        return result;
    }

    static string Base64Url(byte[] bytes)
    {
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
