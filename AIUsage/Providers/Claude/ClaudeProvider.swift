import Foundation

/// Cooldown after Claude answered `429`, kept across app launches so a restart
/// does not immediately hit the shared, tightly limited usage endpoint again.
struct ClaudeRateLimitState: Codable, Equatable, Sendable {
    /// No Claude request is sent before this moment.
    var until: Date
    /// `429` answers since the last successful usage read; drives the backoff.
    var consecutiveHits: Int
}

protocol ClaudeRateLimitPersisting: Sendable {
    func load() -> ClaudeRateLimitState?
    func save(_ state: ClaudeRateLimitState?)
}

struct UserDefaultsClaudeRateLimitStore: ClaudeRateLimitPersisting {
    static let key = "claude.rateLimitState"

    func load() -> ClaudeRateLimitState? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ClaudeRateLimitState.self, from: data)
    }

    func save(_ state: ClaudeRateLimitState?) {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            UserDefaults.standard.removeObject(forKey: Self.key)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

enum ClaudeRateLimitPolicy {
    /// Claude's usage endpoint is shared with Claude Code and Claude.app on the
    /// same account, so it is read at most this often, whatever the cadence.
    static let minimumFetchInterval: TimeInterval = 15 * 60
    static let baseBackoff: TimeInterval = 5 * 60
    static let maximumBackoff: TimeInterval = 60 * 60

    /// 5, 10, 20, 40, then 60 minutes for consecutive `429` answers.
    static func backoff(forConsecutiveHits hits: Int) -> TimeInterval {
        let exponent = Double(max(hits, 1) - 1)
        return min(baseBackoff * pow(2, exponent), maximumBackoff)
    }

    /// Up to 10% extra, so several clients do not retry in lockstep.
    @Sendable static func randomJitter(_ delay: TimeInterval) -> TimeInterval {
        delay * Double.random(in: 0...0.1)
    }
}

actor ClaudeProvider: UsageProvider {
    nonisolated let id = ProviderID.claude

    private let authStore: ClaudeAuthStore
    private let client: ClaudeUsageClient
    private let dateProvider: DateProviding
    private let rateLimitStore: ClaudeRateLimitPersisting
    private let minimumFetchInterval: TimeInterval
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private var rateLimit: ClaudeRateLimitState?
    private var lastSnapshot: ProviderSnapshot?

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        client: ClaudeUsageClient = ClaudeUsageClient(),
        dateProvider: DateProviding = SystemDateProvider(),
        rateLimitStore: ClaudeRateLimitPersisting = UserDefaultsClaudeRateLimitStore(),
        minimumFetchInterval: TimeInterval = ClaudeRateLimitPolicy.minimumFetchInterval,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = ClaudeRateLimitPolicy.randomJitter
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
        self.rateLimitStore = rateLimitStore
        self.minimumFetchInterval = minimumFetchInterval
        self.jitter = jitter
        rateLimit = rateLimitStore.load()
    }

    func fetch() async throws -> ProviderSnapshot {
        let now = dateProvider.now()
        if let lastSnapshot,
           now.timeIntervalSince(lastSnapshot.fetchedAt) < minimumFetchInterval {
            return lastSnapshot
        }
        return try await fetch(credentialReloadsRemaining: 1)
    }

    private func fetch(credentialReloadsRemaining: Int) async throws -> ProviderSnapshot {
        let candidates = authStore.loadCandidates().filter(\.hasUsableAccessToken)
        guard !candidates.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Run `claude` to authenticate."
            )
        }

        try checkCooldown()

        var generation = ClaudeCredentialGeneration(candidates)
        var lastAuthenticationFailure: ProviderFailure?

        for candidate in candidates {
            do {
                let snapshot = try await probe(candidate, generation: &generation)
                recordSuccess(snapshot)
                return snapshot
            } catch ClaudeProviderError.credentialsChanged where credentialReloadsRemaining > 0 {
                return try await fetch(credentialReloadsRemaining: credentialReloadsRemaining - 1)
            } catch let failure as ProviderFailure where failure.kind == .authentication {
                lastAuthenticationFailure = failure
                continue
            }
        }

        throw lastAuthenticationFailure ?? ProviderFailure(
            .authentication,
            "Not logged in. Run `claude` to authenticate."
        )
    }

    private func probe(
        _ initialState: ClaudeCredentialState,
        generation: inout ClaudeCredentialGeneration
    ) async throws -> ProviderSnapshot {
        guard authStore.hasUsageScope(initialState.oauth) else {
            throw ProviderFailure(
                .authentication,
                "Re-login for live usage. Run `claude` and sign in again."
            )
        }

        // No proactive refresh: Claude Code rotates its own token, and racing
        // it doubles the traffic. The app refreshes only after a 401.
        var state = initialState
        var expectedGeneration = generation

        guard let accessToken = nonEmpty(state.oauth.accessToken) else {
            throw ProviderFailure(.authentication, "Claude token is missing. Run `claude` to log in.")
        }

        var response = try await sendUsage(accessToken: accessToken)
        try throwIfRateLimited(response)
        if response.statusCode == 401 || response.statusCode == 403 {
            guard let refreshToken = nonEmpty(state.oauth.refreshToken) else {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `claude` to log in again."
                )
            }
            try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: &expectedGeneration
            )
            guard let refreshedToken = nonEmpty(state.oauth.accessToken) else {
                throw ProviderFailure(.authentication, "Claude session expired.")
            }
            response = try await sendUsage(accessToken: refreshedToken)
            try throwIfRateLimited(response)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `claude` to log in again."
                )
            }
        }

        guard authStore.credentialGeneration() == expectedGeneration else {
            throw ClaudeProviderError.credentialsChanged
        }

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: state.oauth,
            now: dateProvider.now()
        )
        generation = expectedGeneration
        return snapshot
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: inout ClaudeCredentialGeneration
    ) async throws {
        let response: HTTPResponse
        do {
            response = try await client.refreshToken(refreshToken)
        } catch {
            throw transportFailure(error)
        }

        try throwIfRateLimited(response)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = try? ProviderParsing.object(from: response.body)
            let code = ProviderParsing.string(body?["error"])
                ?? ProviderParsing.string(body?["error_description"])
            if code == "invalid_grant" {
                throw ProviderFailure(
                    .authentication,
                    "Session expired. Run `claude` to log in again."
                )
            }
            throw ProviderFailure(
                .invalidResponse,
                "Claude token refresh failed (\(response.statusCode))."
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Claude token refresh failed (\(response.statusCode))."
            )
        }

        let decoded: ClaudeRefreshResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        } catch {
            throw ProviderFailure(.invalidResponse, "Claude returned an invalid refreshed token.")
        }
        guard !decoded.accessToken.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Claude returned an empty refreshed token.")
        }

        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = nonEmpty(decoded.refreshToken) {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt =
                dateProvider.now().timeIntervalSince1970 * 1_000 + expiresIn * 1_000
        }

        do {
            guard try authStore.save(state, ifUnchanged: expectedGeneration) else {
                throw ClaudeProviderError.credentialsChanged
            }
        } catch let error as ClaudeProviderError {
            throw error
        } catch {
            throw ProviderFailure(.storage, "Claude's refreshed login could not be saved.")
        }
        expectedGeneration = expectedGeneration.replacing(state)
    }

    private func sendUsage(accessToken: String) async throws -> HTTPResponse {
        do {
            return try await client.fetchUsage(accessToken: accessToken)
        } catch {
            throw transportFailure(error)
        }
    }

    private func checkCooldown() throws {
        guard let rateLimit, dateProvider.now() < rateLimit.until else { return }
        throw rateLimitedFailure(until: rateLimit.until)
    }

    private func throwIfRateLimited(_ response: HTTPResponse) throws {
        guard response.statusCode == 429 else { return }
        let now = dateProvider.now()
        let hits = (rateLimit?.consecutiveHits ?? 0) + 1
        let backoff = ClaudeRateLimitPolicy.backoff(forConsecutiveHits: hits)
        let delay = max(ProviderParsing.retryAfterInterval(from: response, now: now) ?? 0, backoff)
        let state = ClaudeRateLimitState(
            until: now.addingTimeInterval(delay + max(jitter(delay), 0)),
            consecutiveHits: hits
        )
        rateLimit = state
        rateLimitStore.save(state)
        throw rateLimitedFailure(until: state.until)
    }

    private func recordSuccess(_ snapshot: ProviderSnapshot) {
        lastSnapshot = snapshot
        if rateLimit != nil {
            rateLimit = nil
            rateLimitStore.save(nil)
        }
    }

    private func rateLimitedFailure(until: Date) -> ProviderFailure {
        ProviderFailure(
            .rateLimited,
            "Claude is rate limited. Try again later.",
            retryAt: until
        )
    }

    private func transportFailure(_ error: Error) -> ProviderFailure {
        if let failure = error as? ProviderFailure {
            return failure
        }
        return ProviderFailure(.transient, "Claude could not be reached.")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private enum ClaudeProviderError: Error {
    case credentialsChanged
}
