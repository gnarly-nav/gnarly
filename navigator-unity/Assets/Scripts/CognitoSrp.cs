using System;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

/// <summary>
/// Cognito USER_SRP_AUTH, the same password challenge the website's amazon-cognito-identity-js client uses.
/// This does not create users. Google sign-in stays on the hosted UI.
/// </summary>
public static class CognitoSrp
{
    const string PrimeHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
        "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
        "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D" +
        "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F" +
        "83655D23DCA3AD961C62F356208552BB9ED529077096966D" +
        "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9" +
        "DE2BCBF6955817183995497CEA956AE515D2261898FA0510" +
        "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64" +
        "ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B" +
        "F12FFA06D98A0864D87602733EC86A64521F2B18177B200C" +
        "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31" +
        "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

    static readonly BigInteger Prime = ParseHex(PrimeHex);

    public static string PoolName(string userPoolId)
    {
        var parts = (userPoolId ?? "").Split(new[] { '_' }, 2);
        return parts.Length == 2 && parts[0].Length > 0 && parts[1].Length > 0 ? parts[1] : null;
    }

    public static string Region(string userPoolId)
    {
        var parts = (userPoolId ?? "").Split(new[] { '_' }, 2);
        return parts.Length == 2 && parts[0].Length > 0 ? parts[0] : null;
    }

    public static string RandomSecret()
    {
        var bytes = new byte[128];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        return Hex(bytes);
    }

    public static string PublicValue(string secretHex) => Hex(BigInteger.ModPow(2, ParseHex(secretHex), Prime));

    public static byte[] AuthenticationKey(string poolName, string username, string password, string secretHex, string srpBHex, string saltHex)
    {
        var secret = ParseHex(secretHex);
        var clientA = BigInteger.ModPow(2, secret, Prime);
        var serverB = ParseHex(srpBHex);
        var salt = ParseHex(saltHex);
        if (serverB < 0 || serverB >= Prime || salt == BigInteger.Zero || secret == BigInteger.Zero)
            throw new InvalidOperationException("Cognito returned an invalid password challenge.");
        var k = ParseHex(Sha256Hex(HexToBytes(PadHex(Prime) + PadHex(new BigInteger(2)))));
        var u = ParseHex(Sha256Hex(HexToBytes(PadHex(clientA) + PadHex(serverB))));
        if (u == BigInteger.Zero) throw new InvalidOperationException("Cognito returned an invalid password challenge.");
        var identity = Encoding.UTF8.GetBytes(poolName + username + ":" + password);
        var x = ParseHex(Sha256Hex(HexToBytes(PadHex(salt) + Sha256Hex(identity))));
        var gx = BigInteger.ModPow(2, x, Prime);
        var reduced = (k * gx) % Prime;
        var basis = serverB >= reduced ? serverB - reduced : serverB + Prime - reduced;
        var session = BigInteger.ModPow(basis, secret + u * x, Prime);
        var info = Encoding.UTF8.GetBytes("Caldera Derived Key");
        var material = new byte[info.Length + 1];
        Buffer.BlockCopy(info, 0, material, 0, info.Length);
        material[info.Length] = 1;
        byte[] prk;
        using (var hmac = new HMACSHA256(HexToBytes(PadHex(u))))
            prk = hmac.ComputeHash(HexToBytes(PadHex(session)));
        byte[] expanded;
        using (var hmac = new HMACSHA256(prk))
            expanded = hmac.ComputeHash(material);
        var key = new byte[16];
        Buffer.BlockCopy(expanded, 0, key, 0, 16);
        return key;
    }

    public static string ClaimSignature(byte[] key, string poolName, string username, string secretBlock, string timestamp)
    {
        var block = Convert.FromBase64String(secretBlock);
        var message = new byte[Encoding.UTF8.GetByteCount(poolName) + Encoding.UTF8.GetByteCount(username) + block.Length + Encoding.UTF8.GetByteCount(timestamp)];
        var cursor = 0;
        cursor += Encoding.UTF8.GetBytes(poolName, 0, poolName.Length, message, cursor);
        cursor += Encoding.UTF8.GetBytes(username, 0, username.Length, message, cursor);
        Buffer.BlockCopy(block, 0, message, cursor, block.Length);
        cursor += block.Length;
        Encoding.UTF8.GetBytes(timestamp, 0, timestamp.Length, message, cursor);
        using (var hmac = new HMACSHA256(key))
            return Convert.ToBase64String(hmac.ComputeHash(message));
    }

    /// <summary>ddd MMM D HH:mm:ss UTC yyyy. The day is not zero-padded, matching the JavaScript client.</summary>
    public static string Timestamp(DateTime utc)
    {
        var date = utc.Kind == DateTimeKind.Utc ? utc : utc.ToUniversalTime();
        var weekdays = new[] { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        var months = new[] { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        return weekdays[(int)date.DayOfWeek] + " " + months[date.Month - 1] + " " + date.Day
            + " " + date.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + " UTC " + date.Year;
    }

    public static string PadHex(BigInteger value)
    {
        var hex = value.ToString("x");
        if ((hex.Length & 1) == 1) hex = "0" + hex;
        if ("89abcdef".IndexOf(char.ToLowerInvariant(hex[0])) >= 0) hex = "00" + hex;
        return hex;
    }

    public static string JsonString(string value)
    {
        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');
        foreach (var character in value ?? "")
        {
            if (character == '\\' || character == '"') builder.Append('\\').Append(character);
            else if (character == '\n') builder.Append("\\n");
            else if (character == '\r') builder.Append("\\r");
            else if (character < ' ') builder.Append("\\u").Append(((int)character).ToString("x4"));
            else builder.Append(character);
        }
        builder.Append('"');
        return builder.ToString();
    }

    static string Sha256Hex(byte[] data)
    {
        using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(data));
    }

    static string Hex(byte[] bytes)
    {
        var builder = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes) builder.Append(b.ToString("x2"));
        return builder.ToString();
    }

    static string Hex(BigInteger value) => value == BigInteger.Zero ? "0" : value.ToString("x");

    static BigInteger ParseHex(string hex)
    {
        var text = (hex ?? "").Trim();
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) text = text.Substring(2);
        text = text.TrimStart('0');
        if (text.Length == 0) return BigInteger.Zero;
        return BigInteger.Parse("0" + text, NumberStyles.AllowHexSpecifier);
    }

    static byte[] HexToBytes(string hex)
    {
        if ((hex.Length & 1) == 1) hex = "0" + hex;
        var bytes = new byte[hex.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
            bytes[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
        return bytes;
    }
}
