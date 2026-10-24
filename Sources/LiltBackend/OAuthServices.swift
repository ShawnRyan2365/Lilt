import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LiltCore

public final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public protocol UsageFetching: Sendable {
    func fetch(_ credential: Credential) async throws -> UsageSnapshot
}
public struct UsageClient: UsageFetching {
    public init() {}
    public func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        try credential.validate()
        if credential.accessExpired { throw UsageFailure.accessExpired }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.token!)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
            switch response.statusCode {
            case 200: return try UsageParser.parse(data)
            case 401: throw UsageFailure.authentication
            case 403:
                let body = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
                let scopes = credential.oauth["scopes"] as? [String]
                let lacksProfile = scopes.map { !$0.contains("user:profile") } ?? false
                throw body.contains("scope") || body.contains("user:profile") || lacksProfile ? UsageFailure.permission : UsageFailure.authentication
            case 429:
                let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let seconds = Double(header) ?? formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) } ?? 60
                throw UsageFailure.rateLimited(seconds)
            default: throw UsageFailure.invalidResponse
            }
        } catch let error as UsageFailure { throw error }
        catch { throw UsageFailure.network }
    }
}

public protocol TokenRenewing: Sendable {
    func renew(_ credential: Credential) async throws -> Credential
}
public enum RenewalFailure: Error { case rejected, network, invalidResponse }
public struct TokenRenewer: TokenRenewing {
    public init() {}
    public func renew(_ credential: Credential) async throws -> Credential {
        guard let refresh = OAuthDocument.refreshToken(credential.data) else { throw RenewalFailure.rejected }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        let scopes = OAuthDocument.scopes(credential.data)
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RenewalFailure.invalidResponse }
            switch http.statusCode {
            case 200:
                guard let renewed = OAuthDocument.renewed(credential.data, response: data, now: .now) else { throw RenewalFailure.invalidResponse }
                return Credential(data: renewed)
            case 400, 401, 403: throw RenewalFailure.rejected
            default: throw RenewalFailure.network
            }
        } catch let error as RenewalFailure { throw error }
        catch { throw RenewalFailure.network }
    }
}

public protocol IdentityFetching: Sendable {
    func fetch(_ credential: Credential) async -> Data?
}
public struct IdentityClient: IdentityFetching {
    public init() {}
    public func fetch(_ credential: Credential) async -> Data? {
        guard let token = credential.token, !credential.accessExpired else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return OAuthDocument.identityRecord(fromProfile: data)
    }
}
