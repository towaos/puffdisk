import Testing
@testable import PuffdiskCore

struct WeightCalculatorTests {
    let gb = WeightCalculator.gigabyte
    let calculator = WeightCalculator()  // 満腹ライン 50GB

    @Test func stagesAtEachBoundary() {
        #expect(calculator.stage(score: 0) == .one)
        #expect(calculator.stage(score: 5 * gb - 1) == .one)
        #expect(calculator.stage(score: 5 * gb) == .two)
        #expect(calculator.stage(score: 15 * gb) == .three)
        #expect(calculator.stage(score: 30 * gb) == .four)
        #expect(calculator.stage(score: 50 * gb) == .five)
        #expect(calculator.stage(score: 500 * gb) == .five)
    }

    @Test func goingUpUsesTheBoundary() {
        #expect(calculator.stage(score: 15 * gb, previous: .two) == .three)
        #expect(calculator.stage(score: 50 * gb, previous: .one) == .five)
    }

    @Test func goingDownWaitsUntilNinetyPercent() {
        // 区切り 15GB の 90% = 13.5GB
        #expect(calculator.stage(score: 14 * gb, previous: .three) == .three)
        #expect(calculator.stage(score: 13_500_000_000, previous: .three) == .three)
        #expect(calculator.stage(score: 13_499_999_999, previous: .three) == .two)
    }

    @Test func largeDropSkipsStages() {
        #expect(calculator.stage(score: 1 * gb, previous: .five) == .one)
    }

    @Test func userActionDisablesSmoothing() {
        #expect(calculator.stage(score: 14 * gb, previous: .three, smoothing: false) == .two)
    }

    @Test func fullLineChangesBoundaries() {
        let small = WeightCalculator(fullLine: 10 * gb)
        #expect(small.stage(score: 1 * gb) == .two)
        #expect(small.stage(score: 10 * gb) == .five)
        #expect(small.lowerBound(of: .three) == 3 * gb)
    }

    @Test func fullLineIsClamped() {
        #expect(WeightCalculator(fullLine: 1 * gb).fullLine == 5 * gb)
        var calculator = WeightCalculator()
        calculator.fullLine = 1_000 * gb
        #expect(calculator.fullLine == 500 * gb)
    }

    @Test func lowerBounds() {
        #expect(calculator.lowerBound(of: .one) == 0)
        #expect(calculator.lowerBound(of: .two) == 5 * gb)
        #expect(calculator.lowerBound(of: .five) == 50 * gb)
    }
}
