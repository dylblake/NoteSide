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

    // MARK: - Persistence (Keychain)

    private static let keychainService = "com.noteside.license"
    private static let keychainAccount = "license-key"

    static func storedLicenseKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return key
    }

    static func storeLicenseKey(_ key: String) {
        let data = Data(key.utf8)

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func removeLicenseKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
