import AppKit

/// 起動中のアプリ（DESIGN.md 7.7）。アプリの起動・終了の通知で取り直す
@MainActor
final class RunningAppsMonitor {
    private let state: AppState
    private var observers: [NSObjectProtocol] = []

    init(state: AppState) {
        self.state = state
    }

    func start() {
        state.setRunningApps(Self.current())
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state.setRunningApps(Self.current())
                }
            })
        }
    }

    /// 今起動しているアプリ（Bundle ID → 名前）。削除の直前にも取り直す
    static func current() -> [String: String] {
        Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
}
