import Foundation
import OSLog
import PuffdiskCore

/// キャッシュの削除と「残す」（DESIGN.md 6.1・8.2）
@MainActor
final class PurgeCoordinator {
    private static let logger = Logger(subsystem: "com.towaos.puffdisk", category: "Purge")

    private let state: AppState
    private let keepStore: KeepStore
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var deletion: Task<Void, Never>?
    private var deletionRequested = false

    init(state: AppState, keepStore: KeepStore) {
        self.state = state
        self.keepStore = keepStore
        reloadKept()
    }

    // MARK: - 削除

    /// 起動時の回復: `Purge.noindex/` に残っているものの削除を続ける（8.2）
    func recover() {
        emptyPurgeInBackground()
    }

    /// 確認シートで「削除」を押したとき。直前に条件を確かめ直してから移す
    func purge(_ candidates: [Candidate]) {
        guard state.purgeStatus != .moving, state.scanStatus == .idle else { return }
        state.setPurgeStatus(.moving)
        let home = home
        let settings = state.settings
        let kept = Set(state.keptItems.map(\.id))
        // 通知を待たず、押した時点で取り直す（7.7）
        let runningApps = Set(RunningAppsMonitor.current().keys)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Purger(home: home, settings: settings).moveToPurge(candidates, kept: kept, runningApps: runningApps)
            }.value

            for (candidate, reason) in result.skipped {
                Self.logger.notice("削除しない: \(candidate.paths.map { $0.path(percentEncoded: false) }, privacy: .public) \(reason.description, privacy: .public)")
            }
            for candidate in result.moved {
                Self.logger.info("削除待ちへ移した: \(candidate.paths.map { $0.path(percentEncoded: false) }, privacy: .public)")
            }
            state.removeCandidates(Set(result.moved.map(\.id)))
            state.notice = Self.notice(for: result)
            state.setPurgeStatus(.idle)
            emptyPurgeInBackground()
        }
    }

    /// 削除中に新しく移したものがあれば、終わってからもう一度空にする
    private func emptyPurgeInBackground() {
        deletionRequested = true
        if state.purgeStatus == .idle { state.setPurgeStatus(.deleting) }
        guard deletion == nil else { return }
        let home = home
        deletion = Task {
            while deletionRequested {
                deletionRequested = false
                let failures = await Task.detached(priority: .background) { Purger(home: home).emptyPurge() }.value
                if failures > 0 {
                    Self.logger.error("削除待ちのうち \(failures) 項目を消せなかった。次回の起動時にもう一度試す")
                }
            }
            if state.purgeStatus == .deleting { state.setPurgeStatus(.idle) }
            deletion = nil
        }
    }

    static func notice(for result: Purger.Result) -> String {
        let bytes = result.moved.reduce(0) { $0 + $1.reclaimableBytes }
        var parts: [String] = []
        if !result.moved.isEmpty {
            parts.append("\(result.moved.count)件（\(Formatting.bytes(bytes))）を削除しています")
        }
        if !result.skipped.isEmpty {
            let reasons = Set(result.skipped.map(\.reason.description)).sorted().joined(separator: "・")
            parts.append("\(result.skipped.count)件は削除しませんでした（\(reasons)）")
        }
        return parts.joined(separator: "。")
    }

    // MARK: - 残す

    func keep(_ candidate: Candidate) {
        keepStore.add(path: candidate.id, title: candidate.title)
        reloadKept()
    }

    func unkeep(_ id: String) {
        keepStore.remove(path: id)
        reloadKept()
    }

    private func reloadKept() {
        state.setKeptItems(keepStore.all().map { AppState.KeptItem(id: $0.path, title: $0.title) })
    }
}
