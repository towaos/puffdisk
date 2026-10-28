import Foundation
import OSLog
import PuffdiskCore

/// スキャンの実行（DESIGN.md 9.3）。単位の計画 → 前回のサイズで一覧を出す → 1つずつ測り直して差し替える
@MainActor
final class ScanCoordinator {
    private static let logger = Logger(subsystem: "com.towaos.puffdisk", category: "Scan")
    /// 差分で拾えない変化の保険（9.3）。M1 では差分スキャンがないので全体を測り直す
    static let periodicInterval: TimeInterval = 6 * 60 * 60

    private let state: AppState
    private let cache: SizeCacheStore
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init(state: AppState, cache: SizeCacheStore) {
        self.state = state
        self.cache = cache
    }

    func start() {
        scan(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(userInitiated: false) }
        }
        timer?.tolerance = 10 * 60
    }

    /// - Parameter userInitiated: 再スキャンボタンから。少し高い優先度で測る
    func scan(userInitiated: Bool) {
        // 削除待ちへ移している間は計画し直さない（移したものが一覧に戻らないように）
        guard task == nil, state.purgeStatus != .moving else { return }
        let priority: TaskPriority = userInitiated ? .utility : .background
        let home = home
        let settings = state.settings

        task = Task {
            defer { task = nil }
            let plan = await Task.detached(priority: priority) { Scanner(home: home, settings: settings).plan() }.value
            for skipped in plan.skipped {
                Self.logger.info("走査しない: \(skipped.entryID, privacy: .public) \(skipped.url.path(percentEncoded: false), privacy: .public) \(skipped.reason.description, privacy: .public)")
            }

            // 前回のサイズがある単位は、測り終わるまでその値で一覧に出しておく
            let cached = cache.records(for: plan.units.map(\.id))
            var byUnit: [String: Candidate] = [:]
            for unit in plan.units {
                guard let record = cached[unit.id],
                      let candidate = RuleEngine.candidate(for: unit, stats: record.stats, settings: settings, home: home) else { continue }
                byUnit[unit.id] = candidate
            }
            state.setCandidates(Self.sorted(byUnit.values))
            if state.lastScan == nil, cached.count == plan.units.count, let measuredAt = cached.values.map(\.measuredAt).min() {
                state.scanFinished(at: measuredAt)
            }

            state.scanStarted(total: plan.units.count)
            for (index, unit) in plan.units.enumerated() {
                let stats = await Task.detached(priority: priority) { Scanner.measure(unit) }.value
                cache.store(stats, for: unit.id, at: Date())
                byUnit[unit.id] = RuleEngine.candidate(for: unit, stats: stats, settings: settings, home: home)
                state.setCandidates(Self.sorted(byUnit.values))
                state.scanProgressed(done: index + 1, total: plan.units.count)
            }
            cache.finish(keeping: Set(plan.units.map(\.id)))
            state.scanFinished(at: Date())
        }
    }

    /// カタログの並び順のグループ、その中は大きい順
    static func sorted(_ candidates: some Sequence<Candidate>) -> [Candidate] {
        let groupOrder = Dictionary(CacheCatalog.entries.enumerated().map { ($1.group, $0) }, uniquingKeysWith: min)
        return candidates.sorted {
            let (lhs, rhs) = (groupOrder[$0.group] ?? .max, groupOrder[$1.group] ?? .max)
            return lhs != rhs ? lhs < rhs : $0.reclaimableBytes > $1.reclaimableBytes
        }
    }
}
