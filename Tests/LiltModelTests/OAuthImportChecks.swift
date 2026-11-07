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
        "expiresAt": Int64(Date.now.addingTimeInterval(7200).timeIntervalSince1970 * 1000),
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": NSNull(),
        "rateLimitTier": NSNull()
    ]]
    try SecureFiles.write(JSONSerialization.data(withJSONObject: login), to: file)
    let untouched = Data("fixture-runtime-must-not-change".utf8)
    var held: Data? = untouched
    let scope = RuntimeScope(fixtureHome: home, credentials: .init(read: { held }, write: { held = $0 }, delete: { held = nil }))
    var identityCalls = 0
    var usageCalls = 0
    let model = AppModel(fixture: Library(), runtime: scope, usageFetch: { _ in
        usageCalls += 1
        return UsageSnapshot(fiveHour: UsageWindow(used: 20), sevenDay: UsageWindow(used: 30))
    }, identityFetch: { credential in
        identityCalls += 1
        guard credential.token == access || credential.token == "sk-ant-oat01-fixture-import-access-0002" else { return nil }
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

    let wrapped: [String: Any] = [
        "name": "Fixture wrapped",
        "credentials": [
            "access_token": "sk-ant-oat01-fixture-wrapped-access-0001",
            "refresh_token": "sk-ant-ort01-fixture-wrapped-refresh-0001",
            "expires_at": String(Int64(Date.now.addingTimeInterval(7200).timeIntervalSince1970)),
            "scope": "user:inference user:profile",
            "token_type": "Bearer",
            "account_uuid": "fixture-wrapped-account",
            "email_address": "fixture@example.invalid",
            "org_uuid": "fixture-organization"
        ]
    ]
    try SecureFiles.write(JSONSerialization.data(withJSONObject: wrapped), to: file)
    let importedWrapped = await model.importOAuthCredential(from: file, label: "")
    precondition(importedWrapped == nil && model.accounts.count == 2)
    precondition(model.accounts[1].label == "Fixture wrapped" && model.accounts[1].usageCapability == .verified)
    precondition(model.library.activeID == nil && held == untouched)

    // A login for model requests only (no user:profile, a one-year token) is saved, marked unreadable at once and never
    // asked for quota: the endpoint refuses it every time, and asking anyway can earn a 429.
    var inference = wrapped
    var credentials = inference["credentials"] as! [String: Any]
    credentials["access_token"] = "sk-ant-oat01-fixture-inference-access-0001"
    credentials["refresh_token"] = "sk-ant-ort01-fixture-inference-refresh-0001"
    credentials["expires_at"] = String(Int64(Date.now.addingTimeInterval(365 * 86400).timeIntervalSince1970))
    credentials["scope"] = "user:inference"
    credentials["account_uuid"] = "fixture-inference-account"
    inference["credentials"] = credentials; inference["name"] = "Fixture inference only"
    try SecureFiles.write(JSONSerialization.data(withJSONObject: inference), to: file)
    let readsBefore = usageCalls
    let importedInference = await model.importOAuthCredential(from: file, label: "")
    precondition(importedInference == nil && model.accounts.count == 3)
    let inferenceOnly = model.accounts[2]
    precondition(inferenceOnly.usageCapability == .unavailable && inferenceOnly.issue == UsageFailure.permission.message && usageCalls == readsBefore)
    precondition(model.usageRetryText(inferenceOnly.id) == nil, "A credential that is never asked again is not promised a retry")
    precondition(model.library.activeID == nil && held == untouched)

    try SecureFiles.write(Data("not json".utf8), to: file)
    let malformed = await model.importOAuthCredential(from: file, label: "Malformed")
    precondition(malformed != nil && model.accounts.count == 3 && held == untouched)
    try? FileManager.default.removeItem(at: file)
}
