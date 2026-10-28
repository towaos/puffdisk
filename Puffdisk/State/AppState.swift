import Foundation
import Observation
import PuffdiskCore

/// 画面が見る状態（DESIGN.md 9.4）
@MainActor
@Observable
final class AppState {
    enum ScanStatus: Equatable {
        case idle
        case scanning(done: Int, total: Int)
    }

    /// キャッシュの削除（DESIGN.md 8.2）
    enum PurgeStatus: Equatable {
        case idle
        /// 再確認と `Purge.noindex/` への移動。この間はスキャンしない
        case moving
        /// バックグラウンドでの削除。空き容量が少しずつ増える
        case deleting
    }

    struct KeptItem: Identifiable, Equatable {
        let id: String
        let title: String
    }

    private(set) var calculator = WeightCalculator()
    private(set) var score: Int64 = 0
    private(set) var stage: WeightStage = .one
    var settings = ScanSettings()

    /// スキャンで見つかった候補。「残す」にしたものも含む
    private(set) var allCandidates: [Candidate] = []
    /// 「残す」にしたもの
    private(set) var keptItems: [KeptItem] = []
    private(set) var scanStatus = ScanStatus.idle
    private(set) var purgeStatus = PurgeStatus.idle
    /// 削除の結果など、ポップオーバーの上部に出すお知らせ
    var notice: String?
    /// 確認シートに出している候補（DESIGN.md 6.1）
    var confirmingPurge: [Candidate]?
    private(set) var lastScan: Date?
    /// チェックした候補（`Candidate.id`）
    var selection: Set<String> = []
    /// 一度でも一覧に出た候補。再スキャンで既定のチェックに戻さないため
    private var seen: Set<String> = []

    var spikeLog: [String] = []

    /// 一覧に出す候補（「残す」にしたものを除く）
    var candidates: [Candidate] {
        let kept = Set(keptItems.map(\.id))
        return allCandidates.filter { !kept.contains($0.id) }
    }

    /// 消せそうな量（空く見込み量の合計。スコアではない。DESIGN.md 6.1）
    var reclaimableBytes: Int64 { candidates.reduce(0) { $0 + $1.reclaimableBytes } }

    func total(of category: CandidateCategory) -> Int64 {
        candidates.filter { $0.category == category }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    func selectedCandidates(in category: CandidateCategory) -> [Candidate] {
        candidates.filter { $0.category == category && selection.contains($0.id) }
    }

    func selectedBytes(in category: CandidateCategory) -> Int64 {
        selectedCandidates(in: category).reduce(0) { $0 + $1.reclaimableBytes }
    }

    // MARK: - スキャン

    func scanStarted(total: Int) {
        scanStatus = .scanning(done: 0, total: total)
    }

    func scanProgressed(done: Int, total: Int) {
        scanStatus = .scanning(done: done, total: total)
    }

    /// 候補一覧を差し替える。段階はスキャンが終わったときだけ計算し直す（途中で太ったり痩せたりしないように）
    func setCandidates(_ newCandidates: [Candidate]) {
        allCandidates = newCandidates
        for candidate in newCandidates where !seen.contains(candidate.id) {
            seen.insert(candidate.id)
            if candidate.defaultSelected { selection.insert(candidate.id) }
        }
        selection.formIntersection(newCandidates.map(\.id))
    }

    /// - Parameter scannedAt: 前回のキャッシュから作った一覧のときは、そのときの日時
    func scanFinished(at scannedAt: Date?) {
        scanStatus = .idle
        lastScan = scannedAt
        recalculateScore()
    }

    // MARK: - 残す・削除

    func setKeptItems(_ items: [KeptItem]) {
        keptItems = items
        // 片付けたのに痩せない、を防ぐため、本人の操作ではちらつき防止を使わない（5.2）
        recalculateScore(userAction: true)
    }

    func setPurgeStatus(_ status: PurgeStatus) {
        purgeStatus = status
    }

    /// `Purge.noindex/` へ移したものを一覧から外し、すぐに痩せさせる（8.2）
    func removeCandidates(_ ids: Set<String>) {
        allCandidates.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        recalculateScore(userAction: true)
    }

    private func recalculateScore(userAction: Bool = false) {
        updateScore(WeightCalculator.score(cacheBytes: total(of: .cache), reviewBytes: total(of: .review)), userAction: userAction)
    }

    // MARK: - 段階

    /// - Parameter userAction: 削除・隔離の直後として扱う（ちらつき防止を使わない）
    func updateScore(_ newScore: Int64, userAction: Bool = false) {
        score = max(0, newScore)
        stage = calculator.stage(score: score, previous: stage, smoothing: !userAction)
    }

    func updateFullLine(_ fullLine: Int64) {
        calculator.fullLine = fullLine
        stage = calculator.stage(score: score, previous: stage, smoothing: false)
    }

    func appendSpikeLog(_ message: String) {
        spikeLog.append(message)
        SpikeLogFile.append(message)
    }
}
