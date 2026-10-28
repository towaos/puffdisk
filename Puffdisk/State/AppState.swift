import Foundation
import Observation
import PuffdiskCore

/// 画面が見る状態（DESIGN.md 9.4）。M0 ではスコアをデバッグ用スライダーで動かす
@MainActor
@Observable
final class AppState {
    private(set) var calculator = WeightCalculator()
    private(set) var score: Int64 = 0
    private(set) var stage: WeightStage = .one
    var spikeLog: [String] = []

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
