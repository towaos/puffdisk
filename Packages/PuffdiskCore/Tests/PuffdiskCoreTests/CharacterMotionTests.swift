import Testing
@testable import PuffdiskCore

struct CharacterMotionTests {
    /// 8〜12fps で 1秒前後（DESIGN.md 5.3）
    @Test func transitionsLastAboutASecond() {
        for from in WeightStage.allCases {
            for to in WeightStage.allCases where from != to {
                let seconds = Double(CharacterMotion.transition(from: from, to: to).count) / CharacterMotion.framesPerSecond
                #expect((0.7...1.3).contains(seconds), "\(from) → \(to): \(seconds)秒")
            }
        }
    }

    @Test func transitionStartsAtTheOldStageAndEndsStillAtTheNewOne() {
        for from in WeightStage.allCases {
            for to in WeightStage.allCases where from != to {
                let frames = CharacterMotion.transition(from: from, to: to)
                #expect(frames.first == CharacterFrame(from))
                #expect(frames.last == CharacterFrame(to))
            }
        }
    }

    @Test func noTransitionWithoutAChange() {
        #expect(CharacterMotion.transition(from: .three, to: .three).isEmpty)
    }

    @Test func largeChangesPassThroughTheStagesInBetween() {
        let shrinking = CharacterMotion.transition(from: .five, to: .one).map(\.stage)
        #expect(shrinking == shrinking.sorted().reversed())
        #expect(Set(shrinking) == Set(WeightStage.allCases))

        let growing = CharacterMotion.transition(from: .one, to: .four).map(\.stage)
        #expect(growing == growing.sorted())
        #expect(Set(growing) == [.one, .two, .three, .four])
    }

    /// 枠の高さは 18pt 固定なので、上に伸ばすと切れる
    @Test func neverTallerThanTheCanvas() {
        var all = WeightStage.allCases.flatMap { CharacterMotion.chewing($0) + CharacterMotion.sigh($0) }
        for from in WeightStage.allCases {
            for to in WeightStage.allCases { all += CharacterMotion.transition(from: from, to: to) }
        }
        #expect(all.allSatisfy { $0.scaleY <= 1 })
    }

    /// 段階5の絵を横に伸ばすと D9 の 22pt を超える
    @Test func newStageIsNeverStretchedWider() {
        for from in WeightStage.allCases {
            for to in WeightStage.allCases where from != to {
                let frames = CharacterMotion.transition(from: from, to: to)
                #expect(frames.filter { $0.stage == to }.allSatisfy { $0.scaleX <= 1 })
            }
        }
    }

    /// スキャン中はメニューバーの他の項目を動かさない
    @Test func chewingDoesNotChangeTheWidth() {
        #expect(CharacterMotion.chewing(.three).allSatisfy { $0.stage == .three && $0.scaleX == 1 })
    }

    @Test func chewingRestsLongerThanItMoves() {
        let frames = CharacterMotion.chewing(.two)
        #expect(frames.filter { $0.scaleY == 1 }.count > frames.count / 2)
    }

    @Test func sighReturnsToRest() {
        let frames = CharacterMotion.sigh(.five)
        #expect(frames.first == CharacterFrame(.five))
        #expect(frames.last == CharacterFrame(.five))
    }
}
