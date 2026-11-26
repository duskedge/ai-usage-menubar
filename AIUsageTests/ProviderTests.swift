import XCTest
@testable import AIUsage

final class ProviderTests: XCTestCase {
    func testClaudeRetriesOnceAfter401AndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = ClaudeOAuth(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: "pro",
            rateLimitTier: "max_20x",
            scopes: ["user:profile"]
        )
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: oauth))
        ])
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "expires_in": 3600
            }
            """),
            httpResponse(json: """
            {"five_hour": {"utilization": 31, "resets_at": 1800003600}}
            """)
        ])
        let date = FixedDateProvider(value: now)
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: keychain,
            dateProvider: date
        )
        let provider = ClaudeProvider(
            authStore: store,
            client: ClaudeUsageClient(http: http),
            dateProvider: date,
            rateLimitStore: MemoryClaudeRateLimitStore(),
            jitter: { _ in 0 }
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 31)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            ClaudeAuthStore.usageURL,
            ClaudeAuthStore.refreshURL,
            ClaudeAuthStore.usageURL
        ])
        let saved = try XCTUnwrap(keychain.currentValue(service: "Claude Code-credentials"))
        let savedDocument = try XCTUnwrap(
            ProviderParsing.decodeWithHexFallback(saved, as: ClaudeCredentialsDocument.self)
        )
        XCTAssertEqual(savedDocument.claudeAiOauth?.accessToken, "new-access")
        XCTAssertEqual(savedDocument.claudeAiOauth?.refreshToken, "new-refresh")
    }

    func testClaudeCooldownSkipsSecondRequestAfter429() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = MockHTTPClient([
            httpResponse(429, headers: ["Retry-After": "120"])
        ])
        let provider = makeClaudeProvider(http: http, date: MutableDateProvider(now))

        for _ in 0..<2 {
            await assertClaudeRateLimited(provider, until: now.addingTimeInterval(300))
        }

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testClaudeBacksOffExponentiallyAcrossConsecutive429s() async {
        let date = MutableDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let http = MockHTTPClient((0..<6).map { _ in httpResponse(429) })
        let provider = makeClaudeProvider(http: http, date: date)

        for expected in [300.0, 600, 1_200, 2_400, 3_600, 3_600] {
            let start = date.now()
            await assertClaudeRateLimited(provider, until: start.addingTimeInterval(expected))
            date.advance(by: expected)
        }

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 6)
    }

    func testClaudeHonorsRetryAfterLongerThanBackoffAndAddsJitter() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = MockHTTPClient([httpResponse(429, headers: ["Retry-After": "1800"])])
        let provider = makeClaudeProvider(
            http: http,
            date: MutableDateProvider(now),
            jitter: { $0 * 0.1 }
        )

        await assertClaudeRateLimited(provider, until: now.addingTimeInterval(1_980))
    }

    func testClaudeCooldownSurvivesRelaunch() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MemoryClaudeRateLimitStore()
        let first = makeClaudeProvider(
            http: MockHTTPClient([httpResponse(429)]),
            date: MutableDateProvider(now),
            rateLimitStore: store
        )
        await assertClaudeRateLimited(first, until: now.addingTimeInterval(300))

        let http = MockHTTPClient([httpResponse(json: #"{"five_hour": {"utilization": 1}}"#)])
        let relaunched = makeClaudeProvider(
            http: http,
            date: MutableDateProvider(now.addingTimeInterval(60)),
            rateLimitStore: store
        )
        await assertClaudeRateLimited(relaunched, until: now.addingTimeInterval(300))

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testClaudeCooldownIsNotClearedByTokenRotation() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = claudeKeychain(accessToken: "access")
        let http = MockHTTPClient([httpResponse(429)])
        let provider = makeClaudeProvider(
            http: http,
            date: MutableDateProvider(now),
            keychain: keychain
        )
        await assertClaudeRateLimited(provider, until: now.addingTimeInterval(300))

        try? keychain.writeGenericPasswordForCurrentUser(
            service: "Claude Code-credentials",
            value: encodedJSON(ClaudeCredentialsDocument(
                claudeAiOauth: claudeOAuth(accessToken: "rotated-by-claude-code", now: now)
            ))
        )
        await assertClaudeRateLimited(provider, until: now.addingTimeInterval(300))

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testClaudeTokenRefresh429StartsCooldown() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(429)
        ])
        let provider = makeClaudeProvider(http: http, date: MutableDateProvider(now))

        for _ in 0..<2 {
            await assertClaudeRateLimited(provider, until: now.addingTimeInterval(300))
        }

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            ClaudeAuthStore.usageURL,
            ClaudeAuthStore.refreshURL
        ])
    }

    func testClaudeDoesNotRefreshTokenProactively() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = claudeKeychain(
            accessToken: "access",
            expiresAt: (now.timeIntervalSince1970 + 60) * 1_000
        )
        let http = MockHTTPClient([httpResponse(json: #"{"five_hour": {"utilization": 12}}"#)])
        let provider = makeClaudeProvider(
            http: http,
            date: MutableDateProvider(now),
            keychain: keychain
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 12)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [ClaudeAuthStore.usageURL])
    }

    func testClaudeReusesSnapshotWithinMinimumInterval() async throws {
        let date = MutableDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let http = MockHTTPClient([
            httpResponse(json: #"{"five_hour": {"utilization": 10}}"#),
            httpResponse(json: #"{"five_hour": {"utilization": 20}}"#)
        ])
        let provider = makeClaudeProvider(
            http: http,
            date: date,
            minimumFetchInterval: ClaudeRateLimitPolicy.minimumFetchInterval
        )

        let first = try await provider.fetch()
        date.advance(by: 14 * 60)
        let cached = try await provider.fetch()
        date.advance(by: 2 * 60)
        let fresh = try await provider.fetch()

        XCTAssertEqual(first.sessionWindow?.usedPercent, 10)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(fresh.sessionWindow?.usedPercent, 20)
        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testClaudeSuccessResetsBackoff() async throws {
        let date = MutableDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let store = MemoryClaudeRateLimitStore()
        let http = MockHTTPClient([
            httpResponse(429),
            httpResponse(429),
            httpResponse(json: #"{"five_hour": {"utilization": 5}}"#),
            httpResponse(429)
        ])
        let provider = makeClaudeProvider(http: http, date: date, rateLimitStore: store)

        await assertClaudeRateLimited(provider, until: date.now().addingTimeInterval(300))
        date.advance(by: 300)
        await assertClaudeRateLimited(provider, until: date.now().addingTimeInterval(600))
        date.advance(by: 600)
        _ = try await provider.fetch()
        XCTAssertNil(store.load())
        await assertClaudeRateLimited(provider, until: date.now().addingTimeInterval(300))
    }

    private func claudeOAuth(
        accessToken: String,
        now: Date,
        expiresAt: Double? = nil
    ) -> ClaudeOAuth {
        ClaudeOAuth(
            accessToken: accessToken,
            refreshToken: "refresh",
            expiresAt: expiresAt ?? (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: ["user:profile"]
        )
    }

    private func claudeKeychain(
        accessToken: String,
        expiresAt: Double? = nil
    ) -> MemoryKeychain {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return MemoryKeychain(currentUser: [
            "Claude Code-credentials": encodedJSON(ClaudeCredentialsDocument(
                claudeAiOauth: claudeOAuth(accessToken: accessToken, now: now, expiresAt: expiresAt)
            ))
        ])
    }

    private func makeClaudeProvider(
        http: MockHTTPClient,
        date: MutableDateProvider,
        keychain: MemoryKeychain? = nil,
        rateLimitStore: MemoryClaudeRateLimitStore = MemoryClaudeRateLimitStore(),
        minimumFetchInterval: TimeInterval = 0,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { _ in 0 }
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles(),
                keychain: keychain ?? claudeKeychain(accessToken: "access"),
                dateProvider: date
            ),
            client: ClaudeUsageClient(http: http),
            dateProvider: date,
            rateLimitStore: rateLimitStore,
            minimumFetchInterval: minimumFetchInterval,
            jitter: jitter
        )
    }

    private func assertClaudeRateLimited(
        _ provider: ClaudeProvider,
        until expected: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetch()
            XCTFail("Expected rate limit", file: file, line: line)
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .rateLimited, file: file, line: line)
            XCTAssertEqual(failure.retryAt, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testCodexProactiveRefreshUsesExactSourceAndFormEncoding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: jwt(expiration: now.timeIntervalSince1970 + 60),
                refreshToken: "refresh +&",
                idToken: "old-id",
                accountID: "account-1"
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        let files = MemoryFiles([
            "~/.config/codex/auth.json": encodedJSON(auth)
        ])
        let http = MockHTTPClient([
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "id_token": "new-id"
            }
            """),
            httpResponse(json: """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 9,
                  "limit_window_seconds": 18000
                }
              }
            }
            """)
        ])
        let date = FixedDateProvider(value: now)
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: MockEnvironment(),
                files: files,
                keychain: MemoryKeychain(),
                dateProvider: date
            ),
            client: CodexUsageClient(http: http),
            dateProvider: date
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Pro 20x")
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 9)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CodexUsageClient.refreshURL,
            CodexUsageClient.usageURL
        ])
        let form = String(data: requests[0].body ?? Data(), encoding: .utf8)
        XCTAssertTrue(form?.contains("refresh_token=refresh%20%2B%26") == true)
        XCTAssertEqual(requests[1].headers["ChatGPT-Account-Id"], "account-1")

        let saved = try XCTUnwrap(files.value(at: "~/.config/codex/auth.json"))
        let savedAuth = try XCTUnwrap(CodexAuthStore.parseAuth(saved))
        XCTAssertEqual(savedAuth.tokens?.accessToken, "new-access")
        XCTAssertEqual(savedAuth.tokens?.refreshToken, "new-refresh")
    }
}
