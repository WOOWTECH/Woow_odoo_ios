import Foundation
import CommonCrypto

/// PBKDF2 PIN hasher — cross-platform compatible with Android SettingsRepository.
/// Same algorithm, iterations, salt length, hash length, and storage format.
///
/// Format: `salt_hex:hash_hex` (e.g., "a1b2c3...:d4e5f6...")
/// Algorithm: PBKDF2WithHmacSHA256, 600,000 iterations, 16-byte salt, 256-bit hash
enum PinHasher {

    /// Number of PBKDF2 iterations. 600,000 is the OWASP-recommended minimum for SHA-256,
    /// balancing brute-force resistance with acceptable verification latency on mobile devices.
    private static let iterations: UInt32 = 600_000

    /// Salt length in bytes. 16 bytes (128 bits) provides sufficient uniqueness
    /// to prevent rainbow-table and pre-computation attacks across all stored PINs.
    private static let saltLength = 16

    /// Derived key length in bytes. 32 bytes (256 bits) matches the output size
    /// of HMAC-SHA256, ensuring the full hash strength is preserved without truncation.
    private static let hashLength = 32

    // MARK: - Exponential Lockout (same as Android)

    /// Escalating lockout durations indexed by failure tier.
    /// Each tier triggers after `maxAttemptsPerTier` consecutive failures:
    /// tier 0 = 30 seconds, tier 1 = 5 minutes, tier 2 = 30 minutes, tier 3+ = 1 hour (cap).
    private static let lockoutDurations: [TimeInterval] = [
        30,       // 5 failures: 30 seconds
        300,      // 10 failures: 5 minutes
        1_800,    // 15 failures: 30 minutes
        3_600,    // 20+ failures: 1 hour (max)
    ]

    /// Number of failed PIN attempts allowed before the first lockout tier activates.
    /// Shared with `AuthViewModel` and `SettingsRepository` to keep the threshold in one place.
    static let maxAttemptsPerTier = 5

    /// Returns lockout duration based on cumulative failed attempts.
    /// Matches Android: 30s → 5min → 30min → 1hr (caps at 1hr).
    /// Returns 0 if under threshold, otherwise escalating lockout.
    static func lockoutDuration(failedAttempts: Int) -> TimeInterval {
        guard failedAttempts >= maxAttemptsPerTier else { return 0 }
        let tierIndex = (failedAttempts / maxAttemptsPerTier) - 1
        let clampedIndex = min(tierIndex, lockoutDurations.count - 1)
        return lockoutDurations[clampedIndex]
    }

    // MARK: - PIN Validation

    /// Validates PIN length (4-6 digits).
    static func isValidLength(_ pin: String) -> Bool {
        pin.count >= 4 && pin.count <= 6
    }

    // MARK: - Hashing

    /// Hashes a PIN using PBKDF2 with a random salt.
    /// Returns `salt_hex:hash_hex` string.
    static func hash(pin: String) -> String? {
        guard isValidLength(pin) else { return nil }

        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt) == errSecSuccess else {
            return nil
        }

        guard let hashBytes = pbkdf2(pin: pin, salt: salt) else { return nil }

        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        let hashHex = hashBytes.map { String(format: "%02x", $0) }.joined()
        return "\(saltHex):\(hashHex)"
    }

    /// Verifies a PIN against a stored `salt_hex:hash_hex` string.
    static func verify(pin: String, against stored: String) -> Bool {
        let parts = stored.split(separator: ":")
        guard parts.count == 2 else { return false }

        let salt = hexToBytes(String(parts[0]))
        let expectedHash = hexToBytes(String(parts[1]))

        guard salt.count == saltLength, expectedHash.count == hashLength else {
            return false
        }

        guard let actualHash = pbkdf2(pin: pin, salt: salt) else { return false }
        // Constant-time comparison to prevent timing side-channel attacks
        return constantTimeEqual(actualHash, expectedHash)
    }

    // MARK: - Private

    private static func pbkdf2(pin: String, salt: [UInt8]) -> [UInt8]? {
        guard let pinData = pin.data(using: .utf8) else { return nil }

        var hash = [UInt8](repeating: 0, count: hashLength)

        let status = pinData.withUnsafeBytes { pinBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                pinData.count,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &hash,
                hashLength
            )
        }

        return status == kCCSuccess ? hash : nil
    }

    /// Constant-time byte array comparison (prevents timing attacks).
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
}
