import Foundation

actor AntigravityProvider: UsageProvider {
    nonisolated let id = ProviderID.antigravity

    private let authStore: AntigravityAuthStore
    private let client: AntigravityUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        client: AntigravityUsageClient = AntigravityUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let auth = try authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Antigravity."
            )
        }
        var token = authStore.usableAccessToken(from: auth)
        if token == nil, let refresh = auth.refreshToken {
            token = await refreshedToken(refresh)
        }
        guard var token else {
            throw ProviderFailure(
                .authentication,
                "Antigravity session expired. Sign in again."
            )
        }

        var summary = await client.cloudCode(
            path: AntigravityUsageClient.summaryPath,
            accessToken: token,
            userAgent: "antigravity"
        )
        if case .authentication = summary,
           let refresh = auth.refreshToken,
           let refreshed = await refreshedToken(refresh) {
            token = refreshed
            summary = await client.cloudCode(
                path: AntigravityUsageClient.summaryPath,
                accessToken: token,
                userAgent: "antigravity"
            )
        }
        if case .authentication = summary {
            throw ProviderFailure(
                .authentication,
                "Antigravity session expired. Sign in again."
            )
        }

        let planData: Data?
        switch await client.cloudCode(
            path: AntigravityUsageClient.planPath,
            accessToken: token,
            userAgent: "agy"
        ) {
        case let .success(data): planData = data
        case .authentication, .unavailable: planData = nil
        }
        let plan = AntigravityUsageMapper.plan(planData)
        let now = dateProvider.now()
        var snapshot: ProviderSnapshot?
        if case let .success(data) = summary {
            snapshot = AntigravityUsageMapper.summary(
                data, planName: plan, now: now
            )
        }
        if let snapshot, snapshot.windows.contains(where: {
            $0.kind == .session || $0.kind == .weekly
        }) {
            return snapshot
        }

        let models = await client.cloudCode(
            path: AntigravityUsageClient.modelsPath,
            accessToken: token,
            userAgent: "antigravity"
        )
        if case let .success(data) = models,
           let supplemented = AntigravityUsageMapper.supplementGemini(
               snapshot, modelsData: data, planName: plan, now: now
           ) {
            return supplemented
        }
        // An optional Gemini request must not discard a valid Claude reading.
        if let snapshot { return snapshot }
        switch models {
        case .success:
            throw ProviderFailure(
                .invalidResponse,
                "Antigravity quota data is unavailable."
            )
        case .authentication:
            throw ProviderFailure(
                .authentication,
                "Antigravity session expired. Sign in again."
            )
        case .unavailable:
            throw ProviderFailure(
                .transient,
                "Antigravity could not be reached."
            )
        }
    }

    private func refreshedToken(_ refresh: String) async -> String? {
        guard let result = await client.refresh(refresh) else {
            return nil
        }
        authStore.cache(
            accessToken: result.token,
            expiresIn: result.expiresIn,
            refreshToken: refresh
        )
        return result.token
    }
}
