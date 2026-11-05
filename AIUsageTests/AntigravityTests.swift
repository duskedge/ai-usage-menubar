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
            dateProvider: FixedDateProvider(value: now),
            localQuota: NoLocalAntigravityQuota()
        )
    }
}

private struct AntigravityTestRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: #"{"access_token":"test-access"}"#, stderr: "")
    }
}

struct NoLocalAntigravityQuota: AntigravityLocalQuotaProviding {
    func snapshot(now: Date) async -> ProviderSnapshot? { nil }
}

final class AntigravityLocalQuotaTests: XCTestCase {
    func testDesktopSummaryIncludesFiveHourAndArgonBuckets() async throws {
        let http = MockHTTPClient([httpResponse(json: #"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.98},{"bucketId":"gemini-weekly","remainingFraction":1},{"bucketId":"gemini-argon-wtu-weekly","remainingFraction":0.62,"resetTime":1800600000}]}]}}"#)])
        let client = AntigravityLocalQuotaClient(discovery: LocalTestEndpoints(), http: http)
        let provider = AntigravityProvider(localQuota: client)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .argonWeekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [2, 0, 38])
        XCTAssertEqual(snapshot.window(for: .argonWeekly)?.resetsAt, Date(timeIntervalSince1970: 1800600000))
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.first?.url.host, "127.0.0.1")
        XCTAssertEqual(requests.first?.headers["X-Codeium-Csrf-Token"], "test-csrf")
    }

    func testLocalFailureDoesNotInventQuota() async {
        for response in [httpResponse(401), httpResponse(json: "invalid"), httpResponse(json: "{}") ] {
            let client = AntigravityLocalQuotaClient(discovery: LocalTestEndpoints(), http: MockHTTPClient([response]))
            let snapshot = await client.snapshot(now: Date())
            XCTAssertNil(snapshot)
        }
    }

    func testDiscoverySkipsInvalidFilesAndPrefersNewestLiveDaemon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, port) in [12345, 23456].enumerated() {
            let url = directory.appendingPathComponent("hub_\(port).json")
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "httpsPort": port, "csrfToken": "fixture"
            ])
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: url.path)
        }
        try Data(#"{"pid":0,"httpsPort":65536,"csrfToken":"fixture"}"#.utf8)
            .write(to: directory.appendingPathComponent("hub_bad.json"))
        XCTAssertEqual(AntigravityDaemonDiscovery(directory: directory).endpoints().map(\.port), [23456, 12345])
    }
}

private struct LocalTestEndpoints: AntigravityLocalEndpointDiscovering {
    func endpoints() -> [AntigravityLocalEndpoint] {
        [AntigravityLocalEndpoint(port: 12345, csrfToken: "test-csrf")]
    }
}
