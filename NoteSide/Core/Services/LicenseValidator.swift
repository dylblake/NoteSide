import CryptoKit
import Foundation

struct LicenseValidator {

    // MARK: - Replace this with your actual public key

    // Generate a key pair with: scripts/generate-keypair.sh
    // Then paste the base64 public key here.
    private static let publicKeyBase64 = "cMogaQpzAHqV/ztkXKU4Zf3y2Kd60eVHsQYgET/wwOs="

    struct LicensePayload: Codable {
        let email: String
        let txn: String
        let product: String?
        let issued: String  // ISO 8601 date
    }

    enum ValidationError: LocalizedError {
        case malformed
        case invalidSignature
        case noPublicKey

        var errorDescription: String? {
            switch self {
            case .malformed: return "The license key is malformed."
            case .invalidSignature: return "The license key signature is invalid."
            case .noPublicKey: return "License validation is not configured."
            }
        }
    }

    /// Validates a license key string of the form `base64payload.base64signature`.
    /// Returns the decoded payload if the signature is valid.
    @discardableResult
    static func validate(_ licenseKey: String) throws -> LicensePayload {
        guard publicKeyBase64 != "PASTE_YOUR_PUBLIC_KEY_HERE" else {
            throw ValidationError.noPublicKey
        }

        let cleaned = licenseKey
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        let parts = cleaned.split(separator: ".", maxSplits: 1)

        guard parts.count == 2,
              let payloadData = Data(base64Encoded: String(parts[0])),
              let signatureData = Data(base64Encoded: String(parts[1]))
        else {
            throw ValidationError.malformed
        }

        guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            throw ValidationError.noPublicKey
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw ValidationError.invalidSignature
        }

        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData) else {
            throw ValidationError.malformed
        }

        return payload
    }

    // MARK: - Persistence (UserDefaults)

    private static let licenseDefaultsKey = "com.noteside.license-key"

    static func storedLicenseKey() -> String? {
        if let key = UserDefaults.standard.string(forKey: licenseDefaultsKey) {
            return key
        }

        // Migrate from legacy keychain storage for users upgrading
        // from a version that stored the key there.
        if let key = legacyKeychainLicenseKey() {
            storeLicenseKey(key)
            deleteLegacyKeychainKey()
            return key
        }

        return nil
    }

    static func storeLicenseKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: licenseDefaultsKey)
    }

    static func removeLicenseKey() {
        UserDefaults.standard.removeObject(forKey: licenseDefaultsKey)
    }

    // MARK: - Legacy keychain migration

    private static let keychainService = "com.noteside.license"
    private static let keychainAccount = "license-key"

    private static func legacyKeychainLicenseKey() -> String? {
        // Check data protection keychain
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(dpQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        // Check legacy file-based keychain
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        result = nil
        if SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        return nil
    }

    private static func deleteLegacyKeychainKey() {
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(dpQuery as CFDictionary)

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
