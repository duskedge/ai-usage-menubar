import XCTest
@testable import AIUsage

final class AntigravityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claudeSummary = #"{"groups":[{"buckets":[{"bucketId":"3p-5h","remainingFraction":1},{"bucketId":"3p-weekly","remainingFraction":0.8}]}]}"#
    private let geminiModels = #"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":0.964226,"resetTime":1800003600}},"gemini-flash":{"quotaInfo":{"remainingFraction":0.98,"resetTime":1800003600}}}}"#

    func testPartialSummaryAddsGeminiWithoutReplacingClaude() async throws {
        let http = MockHTTPClient([
            httpResponse(json: claudeSummary), httpResponse(),
            httpResponse(json: geminiModels)
        ])
        let snapshot = try await provider(http).fetch()
        XCTAssertEqual(snapshot.windows.map(\.kind), [.geminiModels, .claudePool, .claudePoolWeekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [4, 0, 20])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(snapshot.window(for: .geminiModels)?.usedPercent, 4)
        XCTAssertEqual(snapshot.menuBarValue(for: .geminiModels, displayMode: .remaining), .percentage(96))
        let paths = await http.capturedRequests().map(\.url.path)
        XCTAssertEqual(paths.last, AntigravityUsageClient.modelsPath)
    }

    func testAuthoritativeGeminiSkipsModelRequest() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.5}]}]}"#),
            httpResponse()
        ])
        let snapshot = try await provider(http).fetch()
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
        let count = await http.capturedRequests().count
        XCTAssertEqual(count, 2)
    }

    func testFailedSupplementPreservesSummary() async throws {
        for response in [httpResponse(401), httpResponse(json: "invalid"), httpResponse(json: "{}"), httpResponse(500)] {
            let http = MockHTTPClient([
                httpResponse(json: claudeSummary), httpResponse(), response,
                httpResponse(500)
            ])
            let snapshot = try await provider(http).fetch()
            XCTAssertEqual(snapshot.windows.map(\.kind), [.claudePool, .claudePoolWeekly])
        }
    }

    func testEmptySummaryUsesObservedModelConsumption() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"groups":[]}"#), httpResponse(),
            httpResponse(json: geminiModels)
        ])
        let snapshot = try await provider(http).fetch()
        XCTAssertEqual(snapshot.windows.map(\.kind), [.geminiModels])
    }

    func testUnreliableModelsDoNotInventZeroOrFullUsage() throws {
        let entries = [
            #""gemini-pro":{"quotaInfo":{"remainingFraction":1,"resetTime":1800003600}}"#,
            #""gemini-pro":{"quotaInfo":{"resetTime":1800003600}}"#,
            #""gemini-pro":{"quotaInfo":{"remainingFraction":0.5}}"#,
            #""gemini-pro":{"quotaInfo":{"remainingFraction":0.5,"resetTime":1799999999}}"#,
            #""gemini-pro":{"isInternal":true,"quotaInfo":{"remainingFraction":0.5,"resetTime":1800003600}}"#,
            #""gemini-pro":{"quotaInfo":{"remainingFraction":-0.5,"resetTime":1800003600}}"#,
            #""claude-pro":{"quotaInfo":{"remainingFraction":0.5,"resetTime":1800003600}}"#
        ]
        for entry in entries {
            XCTAssertNil(AntigravityUsageMapper.supplementGemini(
                nil, modelsData: Data("{\"models\":{\(entry)}}".utf8),
                planName: nil, now: now
            ), entry)
        }
    }

    func testEmptyAndInvalidSummaryDoNotCountAsQuotaData() {
        for json in [#"{"groups":[]}"#, #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":2}]}]}"#] {
            XCTAssertNil(AntigravityUsageMapper.summary(Data(json.utf8), planName: nil, now: now))
        }
    }

    private func provider(_ http: MockHTTPClient) -> AntigravityProvider {
        AntigravityProvider(
            authStore: AntigravityAuthStore(
                runner: AntigravityTestRunner(), files: MemoryFiles(),
                dateProvider: FixedDateProvider(value: now)
            ),
            client: AntigravityUsageClient(http: http),
            dateProvider: FixedDateProvider(value: now)
        )
    }
}

private struct AntigravityTestRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: #"{"access_token":"test-access"}"#, stderr: "")
    }
}
