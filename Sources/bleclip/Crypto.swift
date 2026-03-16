import Foundation
import CryptoKit
import CommonCrypto

enum Crypto {
    private static let saltSize = 16
    private static let iterations: UInt32 = 100_000

    /// Derive a 256-bit key from password + salt using PBKDF2
    private static func deriveKey(password: Data, salt: Data) -> SymmetricKey? {
        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else { return nil }
        return SymmetricKey(data: derivedKey)
    }

    /// Encrypt data with AES-256-GCM
    /// Output format: [salt (16)] [nonce (12)] [ciphertext] [tag (16)]
    static func encrypt(_ plaintext: Data, password: Data) -> Data? {
        var salt = Data(count: saltSize)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }) == errSecSuccess else {
            return nil
        }

        guard let key = deriveKey(password: password, salt: salt) else { return nil }

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            // sealedBox.combined = nonce (12) + ciphertext + tag (16)
            guard let combined = sealedBox.combined else { return nil }

            var result = Data(capacity: saltSize + combined.count)
            result.append(salt)
            result.append(combined)
            return result
        } catch {
            Logger.debug("Crypto: encryption failed: \(error)")
            return nil
        }
    }

    /// Decrypt data encrypted with encrypt()
    static func decrypt(_ data: Data, password: Data) -> Data? {
        guard data.count > saltSize else {
            Logger.debug("Crypto: data too short to decrypt (\(data.count) bytes)")
            return nil
        }

        let salt = data.subdata(in: 0..<saltSize)
        let combined = data.subdata(in: saltSize..<data.count)

        guard let key = deriveKey(password: password, salt: salt) else { return nil }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return plaintext
        } catch {
            Logger.debug("Crypto: decryption failed (wrong password or corrupted data)")
            return nil
        }
    }
}
