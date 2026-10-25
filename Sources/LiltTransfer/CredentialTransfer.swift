import Crypto
import CryptoExtras
import Foundation
import LiltCore

/// A passphrase-encrypted archive of accounts, for moving them to another machine once. It is not a sync: nothing
/// is kept up to date afterwards. Whoever has the file and the passphrase can use every account in it.
///
/// Format `lilt-credential-export` version 1, a JSON object with exactly these fields:
/// `format`, `version`, `kdf` (`name` scrypt, `N` 65536, `r` 8, `p` 1, `dkLen` 32), `salt` (16 random bytes),
/// `nonce` (12 random bytes) and `ciphertext` (AES-256-GCM ciphertext followed by its 16-byte tag), all binary values
/// as canonical base64. The key is scrypt of the passphrase's UTF-8 bytes exactly as typed. The additional
/// authenticated data is `headerData`: every field but the ciphertext, spelled out line by line, so a changed
/// parameter fails authentication and the bytes do not depend on any JSON encoder.
///
/// Only one parameter set is accepted, and it is checked before any key is derived, so a crafted file cannot make the
/// reader allocate gigabytes or run for minutes. Sizes are capped before decoding as well.
public enum CredentialTransfer {
    public typealias TransferAccount = TransferItem

    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidAccount
        case invalidPassphraseOrArchive

        public var errorDescription: String? {
            switch self {
            case .invalidAccount: "账号数据无效或超出导出限制。"
            case .invalidPassphraseOrArchive: "口令错误，或归档已损坏、被修改。"
            }
        }
    }

    public static let fileExtension = "lilt-credential-export"
    public static let maximumArchiveBytes = 512 * 1024
    public static let maximumPlaintextBytes = 320 * 1024
    public static let maximumAccounts = 256
    public static let maximumLabelBytes = 1024
    public static let maximumCredentialBytes = 64 * 1024
    public static let maximumIdentityBytes = 16 * 1024
    /// Exports ask for at least this many characters: the archive may travel, and scrypt only slows guessing down.
    public static let minimumPassphraseCharacters = 14

    private static let format = "lilt-credential-export"
    private static let version = 1
    private static let saltBytes = 16
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let fixedKDF = KDFParameters(name: "scrypt", n: 65_536, r: 8, p: 1, dkLen: 32)

    private struct KDFParameters: Codable, Equatable, Sendable {
        var name: String
        var n: Int
        var r: Int
        var p: Int
        var dkLen: Int

        enum CodingKeys: String, CodingKey {
            case name, r, p, dkLen
            case n = "N"
        }
    }

    private struct Envelope: Codable, Sendable {
        var format: String
        var version: Int
        var kdf: KDFParameters
        var salt: String
        var nonce: String
        var ciphertext: String
    }

    private struct Plaintext: Codable, Sendable {
        var exportedAt: Date
        var accounts: [TransferItem]
    }

    /// Why `passphrase` is not good enough for an export, or nil. Imports take whatever was used.
    public static func passphraseProblem(_ passphrase: String, confirmation: String? = nil) -> String? {
        if passphrase.count < minimumPassphraseCharacters { return "口令至少 \(minimumPassphraseCharacters) 个字符。" }
        if let confirmation, confirmation != passphrase { return "两次输入的口令不一致。" }
        return nil
    }

    /// The authenticated header. Changing any of these lines changes the bytes and the archive fails to open.
    static func headerData(format: String, version: Int, salt: String, nonce: String) -> Data {
        let kdf = fixedKDF
        return Data([format, "version=\(version)", "kdf=\(kdf.name)", "N=\(kdf.n)", "r=\(kdf.r)", "p=\(kdf.p)",
                     "dkLen=\(kdf.dkLen)", "salt=\(salt)", "nonce=\(nonce)"].joined(separator: "\n").utf8)
    }

    public static func export(_ accounts: [TransferItem], passphrase: String, at now: Date = .now) throws -> Data {
        guard !passphrase.utf8.isEmpty else { throw Failure.invalidPassphraseOrArchive }
        try validateAccounts(accounts)
        do {
            let plaintext = try makeEncoder().encode(Plaintext(exportedAt: now, accounts: accounts))
            guard plaintext.count <= maximumPlaintextBytes else { throw Failure.invalidAccount }
            let salt = randomBytes(count: saltBytes).base64EncodedString()
            let nonce = AES.GCM.Nonce()
            let nonceText = Data(nonce).base64EncodedString()
            let key = try deriveKey(passphrase: passphrase, salt: Data(base64Encoded: salt)!)
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce,
                                          authenticating: headerData(format: format, version: version, salt: salt, nonce: nonceText))
            let envelope = Envelope(format: format, version: version, kdf: fixedKDF, salt: salt, nonce: nonceText,
                                    ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString())
            let archive = try makeEncoder().encode(envelope)
            guard archive.count <= maximumArchiveBytes else { throw Failure.invalidAccount }
            return archive
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalidPassphraseOrArchive
        }
    }

    /// Every failure, from a malformed file to a wrong passphrase, reads the same: telling them apart would tell an
    /// attacker which guesses got further.
    public static func importArchive(_ data: Data, passphrase: String) throws -> [TransferItem] {
        do {
            guard !passphrase.utf8.isEmpty else { throw Failure.invalidPassphraseOrArchive }
            let envelope = try decodeEnvelope(data)
            let salt = try decodeBase64(envelope.salt, exactBytes: saltBytes)
            let nonceData = try decodeBase64(envelope.nonce, exactBytes: nonceBytes)
            let combined = try decodeBase64(envelope.ciphertext, minimumBytes: tagBytes, maximumBytes: maximumPlaintextBytes + tagBytes)
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                               ciphertext: combined.prefix(combined.count - tagBytes),
                                               tag: combined.suffix(tagBytes))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: headerData(format: envelope.format, version: envelope.version,
                                                                                         salt: envelope.salt, nonce: envelope.nonce))
            guard plaintext.count <= maximumPlaintextBytes else { throw Failure.invalidPassphraseOrArchive }
            try validatePlaintextStructure(plaintext)
            let decoded = try makeDecoder().decode(Plaintext.self, from: plaintext)
            try validateAccounts(decoded.accounts)
            return decoded.accounts
        } catch {
            throw Failure.invalidPassphraseOrArchive
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        try KDF.Scrypt.deriveKey(from: Data(passphrase.utf8), salt: salt, outputByteCount: fixedKDF.dkLen,
                                 rounds: fixedKDF.n, blockSize: fixedKDF.r, parallelism: fixedKDF.p)
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The whitelist runs on the raw JSON before anything is decoded: an unknown field, a missing one or a different
    /// KDF parameter is refused before scrypt is ever called.
    private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard !data.isEmpty, data.count <= maximumArchiveBytes,
              let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(dictionary.keys) == ["format", "version", "kdf", "salt", "nonce", "ciphertext"],
              let kdf = dictionary["kdf"] as? [String: Any],
              Set(kdf.keys) == ["name", "N", "r", "p", "dkLen"] else {
            throw Failure.invalidPassphraseOrArchive
        }
        let envelope = try makeDecoder().decode(Envelope.self, from: data)
        guard envelope.format == format, envelope.version == version, envelope.kdf == fixedKDF else {
            throw Failure.invalidPassphraseOrArchive
        }
        return envelope
    }

    private static func decodeBase64(_ value: String, exactBytes: Int) throws -> Data {
        try decodeBase64(value, minimumBytes: exactBytes, maximumBytes: exactBytes)
    }

    private static func decodeBase64(_ value: String, minimumBytes: Int, maximumBytes: Int) throws -> Data {
        guard value.utf8.count <= (maximumBytes + 2) / 3 * 4, let decoded = Data(base64Encoded: value),
              decoded.count >= minimumBytes, decoded.count <= maximumBytes,
              decoded.base64EncodedString() == value else {
            throw Failure.invalidPassphraseOrArchive
        }
        return decoded
    }

    private static func validatePlaintextStructure(_ data: Data) throws {
        guard let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(dictionary.keys) == ["exportedAt", "accounts"],
              let accounts = dictionary["accounts"] as? [Any], accounts.count <= maximumAccounts else {
            throw Failure.invalidPassphraseOrArchive
        }
        let required: Set<String> = ["localID", "label", "kind", "credential"]
        for value in accounts {
            guard let account = value as? [String: Any] else { throw Failure.invalidPassphraseOrArchive }
            let keys = Set(account.keys)
            guard keys == required || keys == required.union(["identity"]) else { throw Failure.invalidPassphraseOrArchive }
        }
    }

    private static func validateAccounts(_ accounts: [TransferItem]) throws {
        guard accounts.count <= maximumAccounts else { throw Failure.invalidAccount }
        for account in accounts {
            guard account.label.utf8.count <= maximumLabelBytes,
                  !account.credential.isEmpty, account.credential.count <= maximumCredentialBytes,
                  (account.identity?.count ?? 0) <= maximumIdentityBytes,
                  credential(account.credential, matches: account.kind) else {
                throw Failure.invalidAccount
            }
        }
    }

    /// A full login carries a refresh token and a long-lived token does not; an archive that says otherwise is refused
    /// rather than imported with the wrong abilities.
    private static func credential(_ data: Data, matches kind: AuthKind) -> Bool {
        guard let oauth = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              validToken(oauth["accessToken"]) else { return false }
        switch kind {
        case .oauth:
            return validToken(oauth["refreshToken"])
        case .setupToken:
            guard let refresh = oauth["refreshToken"] else { return true }
            return (refresh as? String)?.isEmpty == true
        }
    }

    private static func validToken(_ value: Any?) -> Bool {
        guard let token = value as? String, !token.isEmpty else { return false }
        return token.allSatisfy { !$0.isWhitespace }
    }
}
