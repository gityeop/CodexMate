import CommonCrypto
import Foundation

/// Reads Desktop's encrypted cache without changing its credentials or refreshing its tokens.
enum ClaudeDesktopCredentialsStore {
    private struct Configuration: Decodable {
        let accountUUID: String?
        let tokenCache: String?

        enum CodingKeys: String, CodingKey {
            case accountUUID = "lastKnownAccountUuid"
            case tokenCache = "oauth:tokenCacheV2"
        }
    }

    static func loadCredentials() throws -> ClaudeOAuthCredentials {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClaudeUsageError.credentialsNotFound
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fileURL))
        guard let accountUUID = configuration.accountUUID,
              let tokenCache = configuration.tokenCache else {
            throw ClaudeUsageError.credentialsNotFound
        }
        guard let encrypted = Data(base64Encoded: tokenCache) else {
            throw ClaudeUsageError.desktopCredentialsInvalid
        }

        let decrypted = try decrypt(encrypted, password: safeStoragePassword())
        return try ClaudeDesktopCredentialsParser.credentials(from: decrypted, accountUUID: accountUUID)
    }

    private static func safeStoragePassword() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeUsageError.keychainReadFailed(process.terminationStatus)
        }
        if output.last == 10 {
            output.removeLast()
        }
        return output
    }

    // Electron safeStorage on macOS uses a v10 prefix and AES-128-CBC with this PBKDF2 key.
    static func decrypt(_ encrypted: Data, password: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)),
              encrypted.count > 3,
              (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128) else {
            throw ClaudeUsageError.desktopCredentialsInvalid
        }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let keyStatus = password.withUnsafeBytes { passwordBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003, &key, key.count
            )
        }
        guard keyStatus == kCCSuccess else {
            throw ClaudeUsageError.decryptionFailed(keyStatus)
        }

        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = plaintext.count
        var count = 0
        let status = ciphertext.withUnsafeBytes { ciphertextBytes in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, ciphertextBytes.baseAddress, ciphertext.count,
                &plaintext, capacity, &count
            )
        }
        guard status == kCCSuccess else {
            throw ClaudeUsageError.decryptionFailed(status)
        }
        return Data(plaintext.prefix(count))
    }
}

enum ClaudeDesktopCredentialsParser {
    private struct Entry: Decodable {
        let token: String
        let expiresAt: Double
    }

    static func credentials(from data: Data, accountUUID: String) throws -> ClaudeOAuthCredentials {
        let entries = try JSONDecoder().decode([String: Entry?].self, from: data)
        let prefix = "acct:\(accountUUID)|9d1c250a-e61b-44d9-88ed-5944d1962f5e:"
        let suffix = ":https://api.anthropic.com:user:inference user:file_upload user:profile"
        guard let entry = entries.first(where: { $0.key.hasPrefix(prefix) && $0.key.hasSuffix(suffix) })?.value,
              !entry.token.isEmpty else {
            throw ClaudeUsageError.credentialsNotFound
        }
        return ClaudeOAuthCredentials(
            accessToken: entry.token,
            expiresAt: Date(timeIntervalSince1970: entry.expiresAt / 1000)
        )
    }
}
