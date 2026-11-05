import CryptoKit
import Foundation
import Security

/// Cognito `USER_SRP_AUTH`, the same password challenge `amazon-cognito-identity-js` uses on the website.
/// The pool prime and HKDF label match that library. This does not create users.
enum CognitoSrp {
    /// 3072-bit group from the Cognito client. Hex is exactly 96 little-endian words.
    private static let primeHex =
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
        "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"

    private static let field = Montgomery(modulus: BigUInt(hex: primeHex))

    static func poolName(_ userPoolID: String) -> String? {
        let parts = userPoolID.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    static func region(_ userPoolID: String) -> String? {
        let parts = userPoolID.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[0]
    }

    /// 1024-bit client secret `a`, hex encoded. `A = g^a mod N` is what InitiateAuth sends as `SRP_A`.
    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CognitoAuthError("Could not start the password challenge.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func publicValue(secretHex: String) throws -> String {
        let value = field.pow(base: BigUInt(limbs: [2]), exponent: BigUInt(hex: secretHex))
        if value.compare(BigUInt(limbs: [0])) == 0 {
            throw CognitoAuthError("Could not start the password challenge.")
        }
        return value.hex()
    }

    /// 16-byte password key for `PASSWORD_CLAIM_SIGNATURE`. `username` is `USER_ID_FOR_SRP`, not the typed email when they differ.
    static func authenticationKey(poolName: String, username: String, password: String, secretHex: String, srpBHex: String, saltHex: String) throws -> Data {
        let prime = field.modulus
        let g = BigUInt(limbs: [2])
        let secret = BigUInt(hex: secretHex)
        let clientA = field.pow(base: g, exponent: secret)
        let serverB = BigUInt(hex: srpBHex)
        let salt = BigUInt(hex: saltHex)
        guard serverB.compare(prime) < 0, salt.compare(BigUInt(limbs: [0])) > 0, secret.compare(BigUInt(limbs: [0])) > 0 else {
            throw CognitoAuthError("Cognito returned an invalid password challenge.")
        }
        let k = BigUInt(hex: sha256Hex(Data(hex: padHex(prime) + padHex(g))))
        let u = BigUInt(hex: sha256Hex(Data(hex: padHex(clientA) + padHex(serverB))))
        guard u.compare(BigUInt(limbs: [0])) > 0 else {
            throw CognitoAuthError("Cognito returned an invalid password challenge.")
        }
        let identity = Data((poolName + username + ":" + password).utf8)
        let x = BigUInt(hex: sha256Hex(Data(hex: padHex(salt) + sha256Hex(identity))))
        let gx = field.pow(base: g, exponent: x)
        let kgx = field.multiply(field.toMontgomery(k), field.toMontgomery(gx))
        let reduced = field.fromMontgomery(kgx)
        let base = serverB.compare(reduced) >= 0 ? serverB.subtracting(reduced) : serverB.adding(prime).subtracting(reduced)
        let exponent = secret.adding(u.multiplying(x))
        let session = field.pow(base: base, exponent: exponent)
        let info = Data("Caldera Derived Key".utf8) + Data([1])
        let ikm = Data(hex: padHex(session))
        let saltBytes = Data(hex: padHex(u))
        let prk = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: saltBytes)))
        let expanded = Data(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: prk)))
        return Data(expanded.prefix(16))
    }

    static func claimSignature(key: Data, poolName: String, username: String, secretBlock: String, timestamp: String) throws -> String {
        guard let block = Data(base64Encoded: secretBlock) else {
            throw CognitoAuthError("Cognito returned an invalid password challenge.")
        }
        var message = Data(poolName.utf8)
        message.append(Data(username.utf8))
        message.append(block)
        message.append(Data(timestamp.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        return mac.base64EncodedString()
    }

    /// `ddd MMM D HH:mm:ss UTC YYYY` in UTC, the string Cognito's JavaScript client signs. The day is not zero-padded.
    static func timestamp(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.weekday, .month, .day, .hour, .minute, .second, .year], from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = weekdays[(parts.weekday ?? 1) - 1]
        let month = months[(parts.month ?? 1) - 1]
        return String(
            format: "%@ %@ %d %02d:%02d:%02d UTC %d",
            weekday, month, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, parts.year ?? 0
        )
    }

    /// Even-length hex with a `00` prefix when the high bit is set, matching `AuthenticationHelper.padHex` for positive integers.
    static func padHex(_ value: BigUInt) -> String {
        var hex = value.hex()
        if hex.count % 2 != 0 { hex = "0" + hex }
        if let first = hex.first, "89abcdef".contains(first) { hex = "00" + hex }
        return hex
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Little-endian base 2^32. Montgomery multiplication keeps the Cognito modexp on a phone.
struct BigUInt {
    var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs.isEmpty ? [0] : limbs
        normalize()
    }

    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = String(text.dropFirst(2)) }
        text = String(text.drop { $0 == "0" })
        if text.isEmpty { text = "0" }
        let width = (text.count + 7) / 8 * 8
        text = String(repeating: "0", count: width - text.count) + text
        var words: [UInt32] = []
        var index = text.count
        while index > 0 {
            let start = text.index(text.startIndex, offsetBy: index - 8)
            let end = text.index(text.startIndex, offsetBy: index)
            words.append(UInt32(text[start..<end], radix: 16) ?? 0)
            index -= 8
        }
        limbs = words
        normalize()
    }

    mutating func normalize() {
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
    }

    func compare(_ other: BigUInt) -> Int {
        if limbs.count != other.limbs.count { return limbs.count > other.limbs.count ? 1 : -1 }
        for pair in zip(limbs.reversed(), other.limbs.reversed()) where pair.0 != pair.1 {
            return pair.0 > pair.1 ? 1 : -1
        }
        return 0
    }

    func adding(_ other: BigUInt) -> BigUInt {
        let count = max(limbs.count, other.limbs.count)
        var out: [UInt32] = []
        out.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let left = index < limbs.count ? UInt64(limbs[index]) : 0
            let right = index < other.limbs.count ? UInt64(other.limbs[index]) : 0
            let sum = left + right + carry
            out.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }
        return BigUInt(limbs: out)
    }

    func subtracting(_ other: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        var borrow: UInt64 = 0
        for index in 0..<limbs.count {
            let left = UInt64(limbs[index])
            let right = index < other.limbs.count ? UInt64(other.limbs[index]) : 0
            let consumed = right + borrow
            if left < consumed {
                out.append(UInt32(truncatingIfNeeded: (left + (UInt64(1) << 32)) - consumed))
                borrow = 1
            } else {
                out.append(UInt32(truncatingIfNeeded: left - consumed))
                borrow = 0
            }
        }
        return BigUInt(limbs: out)
    }

    func multiplying(_ other: BigUInt) -> BigUInt {
        var out = [UInt32](repeating: 0, count: limbs.count + other.limbs.count)
        for i in limbs.indices {
            var carry: UInt64 = 0
            for j in other.limbs.indices {
                let sum = UInt64(out[i + j]) + UInt64(limbs[i]) * UInt64(other.limbs[j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var k = i + other.limbs.count
            while carry > 0 {
                if k == out.count { out.append(0) }
                let sum = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        return BigUInt(limbs: out)
    }

    func hex() -> String {
        if limbs == [0] { return "0" }
        var text = String(limbs[limbs.count - 1], radix: 16)
        if limbs.count > 1 {
            for word in limbs.dropLast().reversed() {
                text += String(format: "%08x", word)
            }
        }
        return text
    }
}

private struct Montgomery {
    let modulus: BigUInt
    let inverse: UInt32
    let rSquared: BigUInt

    init(modulus: BigUInt) {
        self.modulus = modulus
        inverse = Montgomery.inverse(of: ~modulus.limbs[0] &+ 1)
        var r = BigUInt(limbs: [1])
        let bits = modulus.limbs.count * 32
        for _ in 0..<bits {
            r = r.adding(r)
            if r.compare(modulus) >= 0 { r = r.subtracting(modulus) }
        }
        var square = r
        for _ in 0..<bits {
            square = square.adding(square)
            if square.compare(modulus) >= 0 { square = square.subtracting(modulus) }
        }
        rSquared = square
    }

    func toMontgomery(_ value: BigUInt) -> BigUInt { reduce(value.multiplying(rSquared)) }
    func fromMontgomery(_ value: BigUInt) -> BigUInt { reduce(value) }
    func multiply(_ left: BigUInt, _ right: BigUInt) -> BigUInt { reduce(left.multiplying(right)) }

    func pow(base: BigUInt, exponent: BigUInt) -> BigUInt {
        let digits = exponent.hex()
        var result = toMontgomery(BigUInt(limbs: [1]))
        let montBase = toMontgomery(base)
        var started = false
        for character in digits {
            let value = Int(String(character), radix: 16) ?? 0
            for mask in [8, 4, 2, 1] {
                if started { result = multiply(result, result) }
                if value & mask != 0 {
                    result = multiply(result, montBase)
                    started = true
                }
            }
        }
        if !started { return BigUInt(limbs: [1]) }
        return fromMontgomery(result)
    }

    private func reduce(_ value: BigUInt) -> BigUInt {
        let count = modulus.limbs.count
        var words = value.limbs
        if words.count < count * 2 + 1 { words.append(contentsOf: repeatElement(0, count: count * 2 + 1 - words.count)) }
        for i in 0..<count {
            let m = words[i] &* inverse
            var carry: UInt64 = 0
            for j in 0..<count {
                let sum = UInt64(words[i + j]) + UInt64(m) * UInt64(modulus.limbs[j]) + carry
                words[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var k = i + count
            while carry > 0 {
                if k == words.count { words.append(0) }
                let sum = UInt64(words[k]) + carry
                words[k] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                k += 1
            }
        }
        var result = BigUInt(limbs: Array(words[count...]))
        if result.compare(modulus) >= 0 { result = result.subtracting(modulus) }
        return result
    }

    /// Modular inverse of an odd 32-bit value. Cognito's low limb is `2^32-1`, whose inverse is 1.
    private static func inverse(of value: UInt32) -> UInt32 {
        var x: UInt32 = 1
        for _ in 0..<6 {
            x = x &* (UInt32(2) &- value &* x)
        }
        return x
    }
}

private extension Data {
    init(hex: String) {
        var text = hex
        if text.count % 2 != 0 { text = "0" + text }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
