import Darwin
import Foundation
import Security

protocol AntigravityLocalQuotaProviding: Sendable {
    func snapshot(now: Date) async -> ProviderSnapshot?
}

struct AntigravityLocalEndpoint: Sendable {
    let port: Int
    let csrfToken: String
}

protocol AntigravityLocalEndpointDiscovering: Sendable {
    func endpoints() -> [AntigravityLocalEndpoint]
}

struct AntigravityDaemonDiscovery: AntigravityLocalEndpointDiscovering {
    var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity/daemon")

    func endpoints() -> [AntigravityLocalEndpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        // A desktop app started after the CLI may use a different quota context.
        // Prefer the most recently started live daemon; never merge accounts.
        return files.filter {
            $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json"
        }.sorted {
            modified($0) > modified($1)
        }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let hub = try? JSONDecoder().decode(Daemon.self, from: data),
                  hub.pid > 0, (kill(hub.pid, 0) == 0 || errno == EPERM),
                  (1...65535).contains(hub.httpsPort),
                  !hub.csrfToken.isEmpty else { return nil }
            return AntigravityLocalEndpoint(port: hub.httpsPort, csrfToken: hub.csrfToken)
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private struct Daemon: Decodable {
        let pid: Int32
        let httpsPort: Int
        let csrfToken: String
    }
}

struct AntigravityLocalQuotaClient: AntigravityLocalQuotaProviding {
    let discovery: any AntigravityLocalEndpointDiscovering
    let http: any HTTPClient

    init(
        discovery: any AntigravityLocalEndpointDiscovering = AntigravityDaemonDiscovery(),
        http: any HTTPClient = AntigravityLoopbackHTTPClient()
    ) {
        self.discovery = discovery
        self.http = http
    }

    func snapshot(now: Date) async -> ProviderSnapshot? {
        for endpoint in discovery.endpoints().prefix(4) {
            guard (1...65535).contains(endpoint.port),
                  !endpoint.csrfToken.isEmpty,
                  let url = URL(string: "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
            else { continue }
            let request = HTTPRequest(
                method: .post, url: url,
                headers: [
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                    "X-Codeium-Csrf-Token": endpoint.csrfToken
                ],
                body: Data("{}".utf8)
            )
            guard let response = try? await http.send(request),
                  response.statusCode == 200,
                  let snapshot = AntigravityUsageMapper.summary(
                      response.body, planName: nil, now: now
                  ) else { continue }
            return snapshot
        }
        return nil
    }
}

private actor AntigravityLoopbackHTTPClient: HTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme == "https", request.url.host == "127.0.0.1" else {
            throw URLError(.unsupportedURL)
        }
        var value = URLRequest(url: request.url)
        value.httpMethod = request.method.rawValue
        value.httpBody = request.body
        value.allHTTPHeaderFields = request.headers
        let (data, response) = try await session.data(for: value)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResponse(statusCode: response.statusCode, headers: [:], body: data)
    }
}

private final class LoopbackTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Antigravity's local daemon uses a self-signed certificate. This
        // exception is isolated to literal loopback HTTPS, never provider APIs.
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Do not forward the daemon's CSRF credential to any redirect target.
        completionHandler(nil)
    }
}
