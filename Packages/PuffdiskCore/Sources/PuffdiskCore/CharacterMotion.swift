/// アニメーションの1コマ（DESIGN.md 5.3）。絵は下端の中央を基準に伸び縮みさせる
public struct CharacterFrame: Equatable, Sendable {
    public var stage: WeightStage
    public var scaleX: Double
    public var scaleY: Double

    public init(_ stage: WeightStage, scaleX: Double = 1, scaleY: Double = 1) {
        self.stage = stage
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}

/// イベントごとのコマ送り（DESIGN.md 5.3）。描くのはアプリ側で、ここはコマの並びを決めるだけ
public enum CharacterMotion {
    public static let framesPerSecond = 10.0

    /// スキャン中の1周: もぐもぐしてから少し休む。目を引き続けないように動き続けない（4章）。
    /// 横には伸ばさない（メニューバーの他の項目を動かさない）
    public static func chewing(_ stage: WeightStage) -> [CharacterFrame] {
        let chew = [0.95, 0.95, 1, 1].map { CharacterFrame(stage, scaleY: $0) }
        let rest = Array(repeating: CharacterFrame(stage), count: 13)
        return chew + chew + chew + rest
    }

    /// 段階が変わったとき。上がるならぷくっと膨らみ、下がるならしゅっと縮む。間の段階の絵も通る
    public static func transition(from: WeightStage, to: WeightStage) -> [CharacterFrame] {
        if to > from {
            return [CharacterFrame(from), CharacterFrame(from, scaleX: 1.03, scaleY: 0.98)]
                + stages(between: from, and: to).map { CharacterFrame($0, scaleX: 1.04, scaleY: 0.96) }
                // 新しい段階の絵は横に伸ばさない（幅を D9 の 16〜22pt に収める）
                + [
                    CharacterFrame(to, scaleY: 0.94),
                    CharacterFrame(to, scaleY: 0.94),
                    CharacterFrame(to, scaleY: 0.97),
                    CharacterFrame(to, scaleY: 0.99),
                    CharacterFrame(to),
                ]
        }
        if to < from {
            return [CharacterFrame(from), CharacterFrame(from, scaleX: 0.97), CharacterFrame(from, scaleX: 0.94)]
                + stages(between: from, and: to).map { CharacterFrame($0, scaleX: 0.94) }
                + [
                    CharacterFrame(to, scaleX: 0.93),
                    CharacterFrame(to, scaleX: 0.93),
                    CharacterFrame(to, scaleX: 0.97),
                    CharacterFrame(to, scaleY: 0.97),
                    CharacterFrame(to),
                ]
        }
        return []
    }

    /// 段階5が続いているときのため息: ゆっくりしぼんで戻る
    public static func sigh(_ stage: WeightStage) -> [CharacterFrame] {
        [1, 0.98, 0.96, 0.94, 0.92, 0.92, 0.92, 0.94, 0.96, 0.98, 1].map { CharacterFrame(stage, scaleY: $0) }
    }

    private static func stages(between a: WeightStage, and b: WeightStage) -> [WeightStage] {
        let between = WeightStage.allCases.filter { $0 > min(a, b) && $0 < max(a, b) }
        return a < b ? between : between.reversed()
    }
}
