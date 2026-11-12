import Foundation

private struct CursorRefreshResponse: Decodable {
    let accessToken: String?
    let shouldLogout: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case shouldLogout, error
    }
}

actor CursorProvider: UsageProvider {
    nonisolated let id = ProviderID.cursor

    private let authStore: CursorAuthStore
    private let client: CursorUsageClient
    private let dateProvider: DateProviding
    private var safeStorage: CursorSafeStorage

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        client: CursorUsageClient = CursorUsageClient(),
        dateProvider: DateProviding = SystemDateProvider(),
        safeStorage: CursorSafeStorage = CursorSafeStorage()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
        self.safeStorage = safeStorage
    }

    func fetch() async throws -> ProviderSnapshot {
        try await fetch(allowKeychainPrompt: false)
    }

    func fetch(allowKeychainPrompt: Bool) async throws -> ProviderSnapshot {
        guard var auth = authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Cursor."
            )
        }
        if let stored = auth.accessToken, CursorSafeStorage.isProtected(stored) {
            auth.accessToken = try safeStorage.accessToken(stored, allowKeychainPrompt: allowKeychainPrompt)
        }
        if authStore.needsRefresh(auth.accessToken) {
            try await refresh(&auth)
        }
        guard var token = auth.accessToken else {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }

        var usage = try await requestUsage(token)
        if usage.statusCode == 401 {
            try await refresh(&auth)
            guard let refreshed = auth.accessToken else {
                throw ProviderFailure(
                    .authentication,
                    "Cursor session expired. Sign in again."
                )
            }
            token = refreshed
            usage = try await requestUsage(token)
        }
        if usage.statusCode == 401 {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        try checkServiceFailure(usage, operation: "usage request")
        let plan = try? await client.fetchPlan(accessToken: token)
        return try CursorUsageMapper.map(
            usageResponse: usage,
            planResponse: plan,
            now: dateProvider.now()
        )
    }

    private func requestUsage(_ token: String) async throws -> HTTPResponse {
        do {
            return try await client.fetchUsage(accessToken: token)
        } catch {
            throw ProviderFailure(
                .transient,
                "Cursor could not be reached."
            )
        }
    }

    private func refresh(_ auth: inout CursorAuthState) async throws {
        if auth.source == .protectedSQLite {
            throw ProviderFailure(
                .authentication,
                "Open Cursor to renew its desktop session, then refresh AI Usage."
            )
        }
        guard let refreshToken = auth.refreshToken else {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        let response: HTTPResponse
        do {
            response = try await client.refresh(refreshToken)
        } catch {
            throw ProviderFailure(
                .transient,
                "Cursor could not refresh its session."
            )
        }
        try checkServiceFailure(response, operation: "session refresh")
        let decoded = try? JSONDecoder().decode(
            CursorRefreshResponse.self, from: response.body
        )
        if response.statusCode == 401
            || decoded?.error == "invalid_grant"
            || decoded?.shouldLogout == true {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        guard (200..<300).contains(response.statusCode),
              let token = decoded?.accessToken,
              !token.isEmpty else {
            throw ProviderFailure(
                .invalidResponse,
                "Cursor session refresh failed (\(response.statusCode))."
            )
        }
        do {
            try authStore.saveAccessToken(
                token,
                source: auth.source
            )
        } catch {
            throw ProviderFailure(
                .storage,
                "Cursor session could not be saved."
            )
        }
        auth.accessToken = token
    }

    private func checkServiceFailure(
        _ response: HTTPResponse,
        operation: String
    ) throws {
        switch response.statusCode {
        case 429:
            throw ProviderFailure(
                .rateLimited,
                "Cursor is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(
                    from: response, now: dateProvider.now()
                )
            )
        case 403, 500..<600:
            throw ProviderFailure(
                .transient,
                "Cursor \(operation) failed (\(response.statusCode))."
            )
        default:
            break
        }
    }
}
