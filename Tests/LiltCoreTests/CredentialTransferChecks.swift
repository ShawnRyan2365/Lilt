import Foundation
import LiltCore
import LiltTransfer

private enum CredentialTransferTestSupport {
    static let passphrase = "  fixture-\u{00E9} \n"
    static let trimmedPassphrase = "fixture-\u{00E9}"
    static let decomposedPassphrase = "  fixture-e\u{0301} \n"

    static let oauthCredential = Data(#"{"claudeAiOauth":{"accessToken":"fixture-oauth-access","refreshToken":"fixture-oauth-refresh","expiresAt":1900000000000,"scopes":["user:inference","user:profile"]}}"#.utf8)
    static let setupCredential = Data(#"{"claudeAiOauth":{"accessToken":"fixture-setup-token","scopes":["user:inference"]}}"#.utf8)
    static let identity = Data(#"{"accountUuid":"fixture-only","emailAddress":"fixture@example.invalid"}"#.utf8)

    static let oauthAccount = CredentialTransfer.TransferAccount(
        localID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        label: "虚构 OAuth",
        kind: .oauth,
        credential: oauthCredential,
        identity: identity
    )
    static let setupAccount = CredentialTransfer.TransferAccount(
        localID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        label: "虚构 setup-token",
        kind: .setupToken,
        credential: setupCredential
    )
    static let accounts = [oauthAccount, setupAccount]

    static func object(_ archive: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: archive) as! [String: Any]
    }

    static func archive(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func changedBase64(_ value: String, index: Int = 0, truncate: Bool = false) -> String {
        var data = Data(base64Encoded: value)!
        if truncate {
            data.removeLast()
        } else {
            data[index] ^= 0x01
        }
        return data.base64EncodedString()
    }

    static func expectImportFailure(_ archive: Data, passphrase: String = passphrase) {
        do {
            _ = try CredentialTransfer.importArchive(archive, passphrase: passphrase)
            preconditionFailure("Expected credential archive import to fail")
        } catch let failure as CredentialTransfer.Failure {
            expectEqual(failure, .invalidPassphraseOrArchive)
        } catch {
            preconditionFailure("Unexpected credential archive error")
        }
    }

    static func expectInvalidAccounts(_ accounts: [CredentialTransfer.TransferAccount]) {
        do {
            _ = try CredentialTransfer.export(accounts, passphrase: passphrase)
            preconditionFailure("Expected credential archive export to fail")
        } catch let failure as CredentialTransfer.Failure {
            expectEqual(failure, .invalidAccount)
        } catch {
            preconditionFailure("Unexpected credential export error")
        }
    }
}

func credentialTransferChecks() throws {
    let support = CredentialTransferTestSupport.self
    expect(CredentialTransfer.passphraseProblem("fixture-short") != nil)
    expect(CredentialTransfer.passphraseProblem("fixture-long-enough", confirmation: "fixture-long-enougH") != nil)
    expect(CredentialTransfer.passphraseProblem("fixture-long-enough", confirmation: "fixture-long-enough") == nil)
    let archive = try CredentialTransfer.export(support.accounts, passphrase: support.passphrase)
    expect(archive.count <= CredentialTransfer.maximumArchiveBytes)
    expectEqual(try CredentialTransfer.importArchive(archive, passphrase: support.passphrase), support.accounts)

    let original = try support.object(archive)
    expectEqual(Set(original.keys), Set(["format", "version", "kdf", "salt", "nonce", "ciphertext"]))
    expectFalse(String(decoding: archive, as: UTF8.self).contains("fixture-oauth-access"))
    expectFalse(String(decoding: archive, as: UTF8.self).contains("虚构 OAuth"))
    let reserialized = try support.archive(original)
    expectEqual(try CredentialTransfer.importArchive(reserialized, passphrase: support.passphrase), support.accounts)

    support.expectImportFailure(archive, passphrase: "fixture-wrong-passphrase")
    support.expectImportFailure(archive, passphrase: support.trimmedPassphrase)
    support.expectImportFailure(archive, passphrase: support.decomposedPassphrase)
    support.expectImportFailure(archive, passphrase: "")

    var ciphertext = original
    ciphertext["ciphertext"] = support.changedBase64(original["ciphertext"] as! String)
    support.expectImportFailure(try support.archive(ciphertext))

    var truncatedCiphertext = original
    truncatedCiphertext["ciphertext"] = support.changedBase64(original["ciphertext"] as! String, truncate: true)
    support.expectImportFailure(try support.archive(truncatedCiphertext))
    support.expectImportFailure(archive.prefix(archive.count - 1))

    var nonce = original
    nonce["nonce"] = support.changedBase64(original["nonce"] as! String, index: 3)
    support.expectImportFailure(try support.archive(nonce))

    var salt = original
    salt["salt"] = support.changedBase64(original["salt"] as! String, index: 4)
    support.expectImportFailure(try support.archive(salt))

    var version = original
    version["version"] = 2
    support.expectImportFailure(try support.archive(version))

    var format = original
    format["format"] = "fixture-other-format"
    support.expectImportFailure(try support.archive(format))

    var extraField = original
    extraField["unexpected"] = "fixture"
    support.expectImportFailure(try support.archive(extraField))

    var badBase64 = original
    badBase64["salt"] = "not*base64"
    support.expectImportFailure(try support.archive(badBase64))

    var noncanonicalBase64 = original
    noncanonicalBase64["salt"] = String((original["salt"] as! String).dropLast())
    support.expectImportFailure(try support.archive(noncanonicalBase64))

    let invalidKDF: [(String, Any)] = [
        ("name", "hkdf"), ("N", 32_768), ("N", Int.max), ("r", 0), ("p", 2), ("dkLen", 64)
    ]
    for (key, value) in invalidKDF {
        var changed = original
        var kdf = original["kdf"] as! [String: Any]
        kdf[key] = value
        changed["kdf"] = kdf
        support.expectImportFailure(try support.archive(changed))
    }

    var missingKDF = original
    var missingKDFParameters = original["kdf"] as! [String: Any]
    missingKDFParameters.removeValue(forKey: "p")
    missingKDF["kdf"] = missingKDFParameters
    support.expectImportFailure(try support.archive(missingKDF))
    support.expectImportFailure(Data(repeating: 0, count: CredentialTransfer.maximumArchiveBytes + 1))

    let maximum = (0..<CredentialTransfer.maximumAccounts).map { _ in
        CredentialTransfer.TransferAccount(
            localID: UUID(), label: "虚构账号", kind: .setupToken, credential: support.setupCredential
        )
    }
    let maximumArchive = try CredentialTransfer.export(maximum, passphrase: support.passphrase)
    expectEqual(try CredentialTransfer.importArchive(maximumArchive, passphrase: support.passphrase).count, 256)
    support.expectInvalidAccounts(maximum + [support.setupAccount])

    let oversizedCredential = CredentialTransfer.TransferAccount(
        localID: UUID(), label: "虚构账号", kind: .setupToken,
        credential: Data(repeating: 1, count: CredentialTransfer.maximumCredentialBytes + 1)
    )
    support.expectInvalidAccounts([oversizedCredential])

    let oversizedIdentity = CredentialTransfer.TransferAccount(
        localID: UUID(), label: "虚构账号", kind: .setupToken, credential: support.setupCredential,
        identity: Data(repeating: 1, count: CredentialTransfer.maximumIdentityBytes + 1)
    )
    support.expectInvalidAccounts([oversizedIdentity])

    let oversizedLabel = CredentialTransfer.TransferAccount(
        localID: UUID(), label: String(repeating: "界", count: CredentialTransfer.maximumLabelBytes),
        kind: .setupToken, credential: support.setupCredential
    )
    support.expectInvalidAccounts([oversizedLabel])

    let paddedCredential = try JSONSerialization.data(withJSONObject: [
        "claudeAiOauth": ["accessToken": "fixture-setup-token", "padding": String(repeating: "x", count: 63_000)]
    ])
    let paddedAccounts = (0..<4).map { _ in
        CredentialTransfer.TransferAccount(
            localID: UUID(), label: "虚构账号", kind: .setupToken, credential: paddedCredential
        )
    }
    support.expectInvalidAccounts(paddedAccounts)

    let forgedOAuth = CredentialTransfer.TransferAccount(
        localID: UUID(), label: "伪造类型", kind: .oauth, credential: support.setupCredential
    )
    let forgedSetup = CredentialTransfer.TransferAccount(
        localID: UUID(), label: "伪造类型", kind: .setupToken, credential: support.oauthCredential
    )
    support.expectInvalidAccounts([forgedOAuth])
    support.expectInvalidAccounts([forgedSetup])

    let first = try CredentialTransfer.export([support.setupAccount], passphrase: support.passphrase)
    let second = try CredentialTransfer.export([support.setupAccount], passphrase: support.passphrase)
    let firstObject = try support.object(first)
    let secondObject = try support.object(second)
    expectFalse(first == second)
    expectFalse(firstObject["salt"] as! String == secondObject["salt"] as! String)
    expectFalse(firstObject["nonce"] as! String == secondObject["nonce"] as! String)
    expectFalse(firstObject["ciphertext"] as! String == secondObject["ciphertext"] as! String)
    expectEqual(try CredentialTransfer.importArchive(second, passphrase: support.passphrase), [support.setupAccount])
}
