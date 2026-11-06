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

    let wrapped: [String: Any] = [
        "name": "fixture-wrapped",
        "credentials": [
            "access_token": "sk-ant-oat01-fixture-wrapped-access-0001",
            "refresh_token": "sk-ant-ort01-fixture-wrapped-refresh-0001",
            "expires_at": "1900000000",
            "scope": "user:inference user:profile",
            "token_type": "Bearer",
            "account_uuid": "fixture-account-wrapped",
            "email_address": "fixture@example.invalid",
            "org_uuid": "fixture-organization"
        ]
    ]
    let converted = try OAuthCredentialFile.parseDocument(JSONSerialization.data(withJSONObject: wrapped))
    expectEqual(OAuthDocument.accessToken(converted.credential), "sk-ant-oat01-fixture-wrapped-access-0001")
    expectEqual(OAuthDocument.refreshToken(converted.credential), "sk-ant-ort01-fixture-wrapped-refresh-0001")
    expectEqual(OAuthDocument.expiry(converted.credential), Date(timeIntervalSince1970: 1_900_000_000))
    expectEqual(OAuthDocument.scopes(converted.credential), ["user:inference", "user:profile"])
    expectEqual(OAuthDocument.Identity(oauthAccount: converted.identity).account, "fixture-account-wrapped")
    expectEqual(converted.suggestedLabel, "fixture-wrapped")

    expectThrows(try OAuthCredentialFile.parse(Data("{}".utf8)))
    expectThrows(try OAuthCredentialFile.parse(Data("not json".utf8)))
    expectThrows(try OAuthCredentialFile.parse(Data(repeating: 32, count: OAuthCredentialFile.maximumBytes + 1)))
}
