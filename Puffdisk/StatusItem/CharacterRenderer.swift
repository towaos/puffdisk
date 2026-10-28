import AppKit
import PuffdiskCore

/// 仮キャラクターの描画（DESIGN.md 5.1）。M4 で本番の絵に差し替える
enum CharacterRenderer {
    static let menuBarHeight: CGFloat = 18

    /// 段階1: 16pt → 段階5: 22pt
    static func menuBarWidth(for stage: WeightStage) -> CGFloat {
        16 + CGFloat(stage.rawValue - 1) * 1.5
    }

    /// 単色のテンプレート画像。`height` を変えるとポップオーバー用の大きな絵にも使える
    static func image(for stage: WeightStage, height: CGFloat = menuBarHeight) -> NSImage {
        let scale = height / menuBarHeight
        let size = NSSize(width: menuBarWidth(for: stage) * scale, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(stage: stage, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(stage: WeightStage, in rect: NSRect) {
        let unit = rect.height / menuBarHeight
        let index = stage.rawValue - 1
        let widthRatio: [CGFloat] = [0.72, 0.78, 0.84, 0.92, 1.0]
        let heightRatio: [CGFloat] = [0.78, 0.76, 0.76, 0.78, 0.80]

        let bodyWidth = rect.width * widthRatio[index]
        let bodyHeight = rect.height * heightRatio[index]
        let body = NSRect(x: rect.midX - bodyWidth / 2, y: rect.minY + unit, width: bodyWidth, height: bodyHeight)

        NSColor.black.setFill()
        NSBezierPath(roundedRect: body, xRadius: bodyWidth * 0.48, yRadius: bodyHeight * 0.55).fill()

        // 目と汗は塗りを抜いて描く（テンプレート画像なので透明部分が背景色になる）
        NSGraphicsContext.current?.compositingOperation = .clear
        let eyeY = body.minY + bodyHeight * 0.52
        let eyeGap = bodyWidth * 0.17
        let eyeSize = 1.8 * unit
        for x in [body.midX - eyeGap, body.midX + eyeGap] {
            if stage >= .four {
                // 苦しそうな横線の目
                NSRect(x: x - eyeSize * 0.7, y: eyeY, width: eyeSize * 1.4, height: unit * 0.9).fill()
            } else {
                NSBezierPath(ovalIn: NSRect(x: x - eyeSize / 2, y: eyeY, width: eyeSize, height: eyeSize)).fill()
            }
        }
        if stage == .five {
            let drop = NSRect(x: body.maxX - 4.2 * unit, y: body.maxY - 6 * unit, width: 2 * unit, height: 3 * unit)
            NSBezierPath(ovalIn: drop).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
