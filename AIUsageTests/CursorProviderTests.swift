import XCTest
@testable import AIUsage

final class CursorProviderTests: XCTestCase {
    func testUsesExistingTokenAndMapsPremiumWeeklyQuota() async throws {
        for period in ["2", #""INCLUDED_USAGE_PERIOD_WEEKLY""#] {
            let http = MockHTTPClient([
                httpResponse(json: """
                {"enabled":true,"billingCycleEnd":1802000000000,
                 "planUsage":{"totalPercentUsed":6}}
                """),
                httpResponse(json: """
                {"planInfo":{"planName":"Premium",
                 "includedUsagePeriod":\(period),
                 "includedUsageResetsAt":"1800600000000"}}
                """)
            ])
            let snapshot = try await provider(http).fetch()

            XCTAssertEqual(snapshot.planName, "Premium")
            XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
            XCTAssertEqual(snapshot.windows.first?.usedPercent, 6)
            XCTAssertEqual(
                snapshot.windows.first?.resetsAt,
                Date(timeIntervalSince1970: 1_800_600_000)
            )
            let requests = await http.capturedRequests()
            XCTAssertEqual(requests.map(\.url), [CursorUsageClient.usageURL, CursorUsageClient.planURL])
            XCTAssertEqual(requests.first?.headers["X-Cursor-Client-Type"], "ide")
        }
    }

    func testForbiddenUsageIsNotReportedAsExpiredSession() async throws {
        let http = MockHTTPClient([httpResponse(403)])

        do {
            _ = try await provider(http).fetch()
            XCTFail("Expected a request failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .transient)
            XCTAssertEqual(failure.message, "Cursor usage request failed (403).")
        }
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [CursorUsageClient.usageURL])
    }

    func testRefreshRateLimitPreservesLastGoodUsage() async throws {
        let http = MockHTTPClient([httpResponse(401), httpResponse(429)])

        do {
            _ = try await provider(http).fetch()
            XCTFail("Expected a rate limit")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .rateLimited)
            XCTAssertEqual(failure.preservesLastGood, true)
        }
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [CursorUsageClient.usageURL, CursorUsageClient.refreshURL])
    }

    func testProtectedDesktopTokenWaitsForManualRefresh() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"planUsage":{"totalPercentUsed":6}}"#),
            httpResponse(),
            httpResponse(json: #"{"planUsage":{"totalPercentUsed":7}}"#),
            httpResponse()
        ])
        let provider = protectedProvider(http)

        do {
            _ = try await provider.fetch()
            XCTFail("Expected manual Keychain authorization")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .storage)
        }
        let initialRequests = await http.capturedRequests()
        XCTAssertEqual(initialRequests.count, 0)

        let unlocked = try await provider.fetch(allowKeychainPrompt: true)
        XCTAssertEqual(unlocked.windows.first?.usedPercent, 6)
        let background = try await provider.fetch()
        XCTAssertEqual(background.windows.first?.usedPercent, 7)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CursorUsageClient.usageURL, CursorUsageClient.planURL,
            CursorUsageClient.usageURL, CursorUsageClient.planURL
        ])
        XCTAssertEqual(Set(requests.compactMap { $0.headers["Authorization"] }),
                       ["Bearer eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDB9.fixture"])
    }

    func testRejectedProtectedDesktopTokenIsLeftForCursorToRenew() async throws {
        let http = MockHTTPClient([httpResponse(401)])
        do {
            _ = try await protectedProvider(http).fetch(allowKeychainPrompt: true)
            XCTFail("Expected Cursor desktop session rejection")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
            XCTAssertEqual(failure.message, "Open Cursor to renew its desktop session, then refresh AI Usage.")
        }
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [CursorUsageClient.usageURL])
    }

    private func protectedProvider(_ http: MockHTTPClient) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: ProtectedCursorDatabase(), keychain: MemoryKeychain()
            ),
            client: CursorUsageClient(http: http),
            safeStorage: CursorSafeStorage(readPassword: { account in
                account == "Cursor Key" ? Data("cursor-test-password".utf8) : nil
            })
        )
    }

    private func provider(_ http: MockHTTPClient) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: NoCursorDatabase(),
                keychain: MemoryKeychain(generic: [
                    CursorAuthStore.accessTokenService: "opaque-test-token",
                    CursorAuthStore.refreshTokenService: "test-refresh-token"
                ])
            ),
            client: CursorUsageClient(http: http)
        )
    }
}

private struct NoCursorDatabase: SQLiteValueReading {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {
        XCTFail("This test must not write to a Cursor database")
    }
}

private struct ProtectedCursorDatabase: SQLiteValueReading {
    // Synthetic Cursor Safe Storage envelope. It contains only a test token.
    private let value = "cursor-safe-storage:v1:djEwP7wIyg9jdwK6dtBMv+sap7jq/8ac8zkk6dfSVxlHvSt2ZgHLxwh2VLJsuFNSP1dbUocHYfuea3urd5seG8C9Xg=="

    func queryValue(path: String, sql: String) throws -> String? {
        if sql.contains(CursorAuthStore.accessTokenKey) || sql.contains(CursorAuthStore.refreshTokenKey) {
            return value
        }
        return nil
    }

    func execute(path: String, sql: String) throws {
        XCTFail("A protected Cursor session must remain read-only")
    }
}
