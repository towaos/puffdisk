/// キャラクターの太さの段階（DESIGN.md 5.2）
public enum WeightStage: Int, CaseIterable, Comparable, Sendable {
    case one = 1, two, three, four, five

    public static func < (lhs: WeightStage, rhs: WeightStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// スコアと段階の計算（DESIGN.md 5.2）
public struct WeightCalculator: Equatable, Sendable {
    /// 満腹ラインに対する段階の区切り（1割 / 3割 / 6割 / 10割）
    public static let boundaries: [Double] = [0.1, 0.3, 0.6, 1.0]
    /// ちらつき防止: 下がるときは区切りの値の 90% を基準にする
    public static let hysteresisFactor = 0.9

    public static let gigabyte: Int64 = 1_000_000_000
    public static let defaultFullLine: Int64 = 30 * gigabyte
    public static let fullLineRange: ClosedRange<Int64> = (5 * gigabyte)...(500 * gigabyte)

    /// 満腹ライン（バイト）。範囲外の値は範囲内に丸める
    public var fullLine: Int64 {
        didSet { fullLine = Self.clampFullLine(fullLine) }
    }

    public init(fullLine: Int64 = defaultFullLine) {
        self.fullLine = Self.clampFullLine(fullLine)
    }

    /// - Parameters:
    ///   - previous: 直前の段階。ちらつき防止に使う
    ///   - smoothing: false にするとちらつき防止を使わない（削除の直後、設定の変更時）
    public func stage(score: Int64, previous: WeightStage? = nil, smoothing: Bool = true) -> WeightStage {
        let raw = stage(score: score, factor: 1.0)
        guard smoothing, let previous, raw < previous else { return raw }
        return min(previous, stage(score: score, factor: Self.hysteresisFactor))
    }

    /// 段階に入る下限のスコア（バイト）。設定画面の目安表示に使う
    public func lowerBound(of stage: WeightStage) -> Int64 {
        guard stage != .one else { return 0 }
        return Int64(Self.boundaries[stage.rawValue - 2] * Double(fullLine))
    }

    private func stage(score: Int64, factor: Double) -> WeightStage {
        let passed = Self.boundaries.filter { Double(score) >= $0 * factor * Double(fullLine) }.count
        return WeightStage(rawValue: passed + 1)!
    }

    private static func clampFullLine(_ value: Int64) -> Int64 {
        min(max(value, fullLineRange.lowerBound), fullLineRange.upperBound)
    }
}
