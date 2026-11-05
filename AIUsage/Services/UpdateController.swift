import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private(set) var availableVersion: String?
    private(set) var isChecking = false

    @ObservationIgnored
    private var updaterController: SPUStandardUpdaterController!

    init(startingUpdater: Bool = true) {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        if startingUpdater {
            // Existing installations may have upstream auto-downloads disabled.
            // Migrate once; later choices made in Sparkle remain user-controlled.
            let key = "duskedgeAutomaticUpdatesConfigured.v1"
            if !UserDefaults.standard.bool(forKey: key) {
                updaterController.updater.automaticallyChecksForUpdates = true
                updaterController.updater.automaticallyDownloadsUpdates = true
                UserDefaults.standard.set(true, forKey: key)
            }
            isChecking = true
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    func checkForUpdates() {
        isChecking = true
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        availableVersion = item.displayVersionString
        isChecking = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        isChecking = false
    }

    func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: any Error
    ) {
        isChecking = false
    }
}
