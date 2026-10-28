import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItemController: StatusItemController?
    private var scanCoordinator: ScanCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scanCoordinator = ScanCoordinator(state: state, cache: SizeCacheStore())
        self.scanCoordinator = scanCoordinator
        statusItemController = StatusItemController(state: state) { scanCoordinator.scan(userInitiated: true) }
        scanCoordinator.start()
    }
}
