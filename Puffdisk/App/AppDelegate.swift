import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItemController: StatusItemController?
    private var scanCoordinator: ScanCoordinator?
    private var purgeCoordinator: PurgeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let persistence = Persistence()
        let scanCoordinator = ScanCoordinator(state: state, cache: SizeCacheStore(persistence: persistence))
        let purgeCoordinator = PurgeCoordinator(state: state, keepStore: KeepStore(persistence: persistence))
        self.scanCoordinator = scanCoordinator
        self.purgeCoordinator = purgeCoordinator

        statusItemController = StatusItemController(state: state, actions: PopoverActions(
            rescan: { scanCoordinator.scan(userInitiated: true) },
            purge: { purgeCoordinator.purge($0) },
            keep: { purgeCoordinator.keep($0) },
            unkeep: { purgeCoordinator.unkeep($0) }
        ))
        purgeCoordinator.recover()
        scanCoordinator.start()
    }
}
