import AppKit
import PuffdiskCore

/// メニューバーのコマ送り（DESIGN.md 5.3）。普段は静止画で、タイマーはイベントの間だけ動かす
@MainActor
final class CharacterAnimator {
    private struct Playback {
        let frames: [CharacterFrame]
        let canvasWidth: CGFloat
        let loops: Bool
        var index = 0
    }

    /// ため息の間隔（5.3 の「数分に一度」）。デバッグ版は確かめやすいように短くする
    #if DEBUG
    private static let sighInterval: TimeInterval = 10
    #else
    private static let sighInterval: TimeInterval = 4 * 60
    #endif

    private let display: (NSImage) -> Void
    private var stage: WeightStage?
    private var isScanning = false
    private var playback: Playback?
    /// 静止画を出しているときの段階
    private var stillStage: WeightStage?
    private var frameTimer: Timer?
    private var sighTimer: Timer?

    /// 「視差効果を減らす」が有効なら動かさない
    private var motionAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(display: @escaping (NSImage) -> Void) {
        self.display = display
    }

    /// - Parameter animated: 段階が変わったときに動かすか
    func update(stage newStage: WeightStage, isScanning: Bool, sighs: Bool, animated: Bool) {
        let previous = stage
        stage = newStage
        self.isScanning = isScanning
        updateSighTimer(enabled: sighs && newStage == .five && !isScanning)

        if let previous, previous != newStage, animated, motionAllowed {
            play(CharacterMotion.transition(from: previous, to: newStage), loops: false)
        } else if playback?.loops != false || previous != newStage {
            // 段階の変化のアニメーションは最後まで見せる
            settle()
        }
    }

    /// 今の状態に合わせて、スキャン中のもぐもぐか静止画にする
    private func settle() {
        guard let stage else { return }
        if isScanning, motionAllowed {
            if playback?.loops != true || playback?.frames.first?.stage != stage {
                play(CharacterMotion.chewing(stage), loops: true)
            }
        } else {
            stopTimer()
            playback = nil
            // 進捗のたびに呼ばれるので、変わったときだけ描き直す
            if stillStage != stage {
                stillStage = stage
                display(CharacterRenderer.menuBarImage(for: stage))
            }
        }
    }

    private func play(_ frames: [CharacterFrame], loops: Bool) {
        let widest = frames.map { CharacterRenderer.menuBarWidth(for: $0.stage) * $0.scaleX }.max() ?? 0
        playback = Playback(frames: frames, canvasWidth: widest.rounded(.up), loops: loops)
        stillStage = nil
        if frameTimer == nil {
            let timer = Timer(timeInterval: 1 / CharacterMotion.framesPerSecond, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.showNextFrame() }
            }
            // ポップオーバーの操作中も止めない
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        }
        showNextFrame()
    }

    private func showNextFrame() {
        guard var current = playback, motionAllowed else {
            playback = nil
            settle()
            return
        }
        let frame = current.frames[current.index]
        // 休みのコマは同じ絵なので描き直さない
        if current.index == 0 || frame != current.frames[current.index - 1] {
            display(CharacterRenderer.menuBarImage(for: frame, canvasWidth: current.canvasWidth))
        }
        current.index += 1
        if current.index < current.frames.count {
            playback = current
        } else if current.loops {
            current.index = 0
            playback = current
        } else {
            playback = nil
            settle()
        }
    }

    private func stopTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func updateSighTimer(enabled: Bool) {
        guard enabled != (sighTimer != nil) else { return }
        sighTimer?.invalidate()
        sighTimer = nil
        guard enabled else { return }
        let timer = Timer(timeInterval: Self.sighInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sigh() }
        }
        timer.tolerance = Self.sighInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        sighTimer = timer
    }

    private func sigh() {
        guard playback == nil, let stage, motionAllowed else { return }
        play(CharacterMotion.sigh(stage), loops: false)
    }
}
