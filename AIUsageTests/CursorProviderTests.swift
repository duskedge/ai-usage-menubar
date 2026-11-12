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
