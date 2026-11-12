import CommonCrypto
import Foundation
import Security

/// Reads only Cursor's desktop access token. The derived key lives in memory
/// for this provider instance, and Keychain access is only attempted on demand.
struct CursorSafeStorage: Sendable {
    static let prefix = "cursor-safe-storage:v1:"
    private static let header = Data("v10".utf8)
    private let readPassword: @Sendable (String) throws -> Data?
    private var key: Data?

    init(readPassword: @escaping @Sendable (String) throws -> Data? = Self.keychainPassword) {
        self.readPassword = readPassword
    }

    static func isProtected(_ token: String?) -> Bool {
        token?.hasPrefix("cursor-safe-storage:") == true
    }

    mutating func accessToken(_ stored: String, allowKeychainPrompt: Bool) throws -> String {
        guard stored.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(stored.dropFirst(Self.prefix.count))),
              data.starts(with: Self.header),
              data.count > Self.header.count,
              (data.count - Self.header.count).isMultiple(of: kCCBlockSizeAES128)
        else {
            throw ProviderFailure(.invalidResponse, "Unsupported Cursor desktop session format.")
        }
        let payload = Data(data.dropFirst(Self.header.count))
        if let key, let token = Self.decrypt(payload, key: key) {
            return token
        }
        key = nil
        guard allowKeychainPrompt else {
            throw ProviderFailure(.storage, "Refresh to unlock Cursor's session in Keychain.")
        }

        for account in ["Cursor Key", "Cursor"] {
            guard let password = try readPassword(account),
                  let candidate = Self.deriveKey(password),
                  let token = Self.decrypt(payload, key: candidate)
            else { continue }
            key = candidate
            return token
        }
        throw ProviderFailure(.storage, "Cursor's session could not be unlocked in Keychain.")
    }

    private static func keychainPassword(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProviderFailure(.storage, "Refresh and allow access to Cursor Safe Storage in Keychain.")
        }
        return result as? Data
    }

    // Cursor uses Electron's macOS Safe Storage encoding. See CodexBar's
    // CursorAppAuth and ChromiumSafeStorage for the compatibility reference.
    private static func deriveKey(_ password: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        input.bindMemory(to: Int8.self).baseAddress, input.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        output.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decrypt(_ payload: Data, key: Data) -> String? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: payload.count + kCCBlockSizeAES128)
        var length = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyBytes.count, ivBytes.baseAddress,
                            input.baseAddress, input.count,
                            output.baseAddress, output.count, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess,
              let token = String(data: plaintext.prefix(length), encoding: .utf8),
              ProviderParsing.jwtExpiration(token) != nil
        else { return nil }
        return token
    }
}
