import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testSignedUpdateConfigurationIsEmbeddedInTheApp() {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://github.com/duskedge/ai-usage-menubar/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(
            info?["SUPublicEDKey"] as? String,
            "hpw3vABcLPG3YymaYORPbhCc2lvguFrZaLiDqCrJffU="
        )
        XCTAssertEqual(info?["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(info?["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info?["SUScheduledCheckInterval"] as? Int, 3_600)
    }
}
