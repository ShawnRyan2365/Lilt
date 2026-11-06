import Foundation
import LiltCore

func oauthCredentialFileChecks() throws {
    let access = "sk-ant-oat01-fixture-access-token-0001"
    let refresh = "sk-ant-ort01-fixture-refresh-token-0001"
    let document: [String: Any] = ["claudeAiOauth": [
        "accessToken": access,
        "refreshToken": refresh,
        "expiresAt": 1_900_000_000_000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": NSNull(),
        "rateLimitTier": NSNull()
    ]]
    let parsed = try OAuthCredentialFile.parse(JSONSerialization.data(withJSONObject: document))
    expectEqual(OAuthDocument.accessToken(parsed), access)
    expectEqual(OAuthDocument.refreshToken(parsed), refresh)
    expectEqual(OAuthDocument.scopes(parsed), ["user:inference", "user:profile"])
    expectEqual(OAuthDocument.expiry(parsed), Date(timeIntervalSince1970: 1_900_000_000))

    var missingRefresh = document
    var oauth = missingRefresh["claudeAiOauth"] as! [String: Any]
    oauth.removeValue(forKey: "refreshToken")
    missingRefresh["claudeAiOauth"] = oauth
    expectThrows(try OAuthCredentialFile.parse(JSONSerialization.data(withJSONObject: missingRefresh)))

    var wrongExpiry = document
    oauth = wrongExpiry["claudeAiOauth"] as! [String: Any]
    oauth["expiresAt"] = true
    wrongExpiry["claudeAiOauth"] = oauth
    expectThrows(try OAuthCredentialFile.parse(JSONSerialization.data(withJSONObject: wrongExpiry)))

    var apiKey = document
    oauth = apiKey["claudeAiOauth"] as! [String: Any]
    oauth["accessToken"] = "sk-ant-api01-fixture-not-an-oauth-login"
    apiKey["claudeAiOauth"] = oauth
    expectThrows(try OAuthCredentialFile.parse(JSONSerialization.data(withJSONObject: apiKey)))

    expectThrows(try OAuthCredentialFile.parse(Data("{}".utf8)))
    expectThrows(try OAuthCredentialFile.parse(Data("not json".utf8)))
    expectThrows(try OAuthCredentialFile.parse(Data(repeating: 32, count: OAuthCredentialFile.maximumBytes + 1)))
}
