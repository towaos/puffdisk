import AppKit
import Observation
import SwiftUI

/// アイコン表示・アニメーション・ポップオーバー開閉（DESIGN.md 9.4）
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let state: AppState
    private let animator: CharacterAnimator
    /// 最初の結果が出るまでは段階の変化を動かさない（起動のたびに膨らまないように）
    private var hasResult = false

    init(state: AppState, actions: PopoverActions) {
        self.state = state
        let statusItem = statusItem
        animator = CharacterAnimator { statusItem.button?.image = $0 }
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state, actions: actions))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }
        render()
        observeStage()
        #if DEBUG
        // 画面確認用: `open Puffdisk.app --args -SnapshotPopover <PNG のパス> [-SnapshotConfirmation YES]`。
        // スキャンを待ってから書き出す
        if let path = UserDefaults.standard.string(forKey: "SnapshotPopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if UserDefaults.standard.bool(forKey: "SnapshotConfirmation") {
                    state.confirmingPurge = state.selectedCandidates
                }
                DispatchQueue.main.async { self.snapshotPopover(to: URL(filePath: path)) }
            }
        }
        #endif
    }

    #if DEBUG
    private func snapshotPopover(to url: URL) {
        guard let view = popover.contentViewController?.view else { return }
        view.frame = NSRect(origin: .zero, size: popover.contentSize)
        view.layoutSubtreeIfNeeded()
        guard let content = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let output = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: content)
        // ポップオーバーの背景は透明なので、ウインドウの背景色を敷く
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        content.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? output.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    private func observeStage() {
        withObservationTracking {
            _ = state.stage
            _ = state.reclaimableBytes
            _ = state.scanStatus
            _ = state.lastScan
            _ = state.sighEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observeStage()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        animator.update(stage: state.stage, isScanning: state.scanStatus != .idle, sighs: state.sighEnabled, animated: hasResult)
        hasResult = state.lastScan != nil
        // 読み上げはスコアではなく実際の合計（DESIGN.md 12）
        button.setAccessibilityLabel("Puffdisk 消せそうな量 \(Formatting.bytes(state.reclaimableBytes))")
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
