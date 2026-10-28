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

    private(set) var calculator = WeightCalculator()
    private(set) var score: Int64 = 0
    private(set) var stage: WeightStage = .one
    var settings = ScanSettings()

    private(set) var candidates: [Candidate] = []
    private(set) var scanStatus = ScanStatus.idle
    private(set) var lastScan: Date?
    /// チェックした候補（`Candidate.id`）
    var selection: Set<String> = []
    /// 一度でも一覧に出た候補。再スキャンで既定のチェックに戻さないため
    private var seen: Set<String> = []

    var spikeLog: [String] = []

    /// 消せそうな量（空く見込み量の合計。スコアではない。DESIGN.md 6.1）
    var reclaimableBytes: Int64 { candidates.reduce(0) { $0 + $1.reclaimableBytes } }

    func total(of category: CandidateCategory) -> Int64 {
        candidates.filter { $0.category == category }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    func selectedBytes(in category: CandidateCategory) -> Int64 {
        candidates.filter { $0.category == category && selection.contains($0.id) }.reduce(0) { $0 + $1.reclaimableBytes }
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
        candidates = newCandidates
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
        let score = WeightCalculator.score(cacheBytes: total(of: .cache), reviewBytes: total(of: .review))
        updateScore(score)
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
