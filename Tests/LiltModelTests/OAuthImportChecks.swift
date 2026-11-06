import Foundation
import LiltCore

@MainActor func oauthImportChecks() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/work/"))
    let file = home.appendingPathComponent("fixture-oauth.json")
    let access = "sk-ant-oat01-fixture-import-access-0001"
    let refresh = "sk-ant-ort01-fixture-import-refresh-0001"
    let login: [String: Any] = ["claudeAiOauth": [
        "accessToken": access,
        "refreshToken": refresh,
        "expiresAt": Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000),
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": NSNull(),
        "rateLimitTier": NSNull()
    ]]
    try SecureFiles.write(JSONSerialization.data(withJSONObject: login), to: file)
    let untouched = Data("fixture-runtime-must-not-change".utf8)
    var held: Data? = untouched
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0 }, delete: { held = nil }))
    var identityCalls = 0
    let model = AppModel(fixture: Library(), runtime: scope, usageFetch: { _ in
        UsageSnapshot(fiveHour: UsageWindow(used: 20), sevenDay: UsageWindow(used: 30))
    }, identityFetch: { _ in
        identityCalls += 1
        return Data(#"{"accountUuid":"fixture-import-account"}"#.utf8)
    })
    let failure = await model.importOAuthCredential(from: file, label: "Fixture imported")
    precondition(failure == nil && model.accounts.count == 1)
    let account = model.accounts[0]
    precondition(account.kind == .oauth && account.label == "Fixture imported")
    precondition(model.library.activeID == nil && held == untouched)
    precondition(account.usageCapability == .verified && identityCalls == 1)
    let stored = try AccountVault.read(account: account.id.uuidString)
    precondition(OAuthDocument.accessToken(stored!) == access && OAuthDocument.refreshToken(stored!) == refresh)

    let duplicate = await model.importOAuthCredential(from: file, label: "Duplicate")
    precondition(duplicate != nil && model.accounts.count == 1 && identityCalls == 1)

    var sameIdentity = login
    var oauth = sameIdentity["claudeAiOauth"] as! [String: Any]
    oauth["accessToken"] = "sk-ant-oat01-fixture-import-access-0002"
    oauth["refreshToken"] = "sk-ant-ort01-fixture-import-refresh-0002"
    sameIdentity["claudeAiOauth"] = oauth
    try SecureFiles.write(JSONSerialization.data(withJSONObject: sameIdentity), to: file)
    let twin = await model.importOAuthCredential(from: file, label: "Twin")
    precondition(twin != nil && model.accounts.count == 1 && identityCalls == 2)

    try SecureFiles.write(Data("not json".utf8), to: file)
    let malformed = await model.importOAuthCredential(from: file, label: "Malformed")
    precondition(malformed != nil && model.accounts.count == 1 && held == untouched)
    try? FileManager.default.removeItem(at: file)
}
