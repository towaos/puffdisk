import AppKit
import Observation
import SwiftUI

/// アイコン表示・ポップオーバー開閉（DESIGN.md 9.4）。アニメーションは M4
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }
        render()
        observeStage()
    }

    private func observeStage() {
        withObservationTracking {
            _ = state.stage
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observeStage()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = CharacterRenderer.image(for: state.stage)
        button.setAccessibilityLabel("Puffdisk 段階 \(state.stage.rawValue)")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
