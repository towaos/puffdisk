import AppKit
import PuffdiskCore
import SwiftUI

/// キャラクターの絵（DESIGN.md 5.1）。絵は `Tools/make-character-assets.swift` で原画から作る
enum CharacterRenderer {
    static let menuBarHeight: CGFloat = 18

    /// 段階1: 16pt → 段階5: 22pt
    static func menuBarWidth(for stage: WeightStage) -> CGFloat {
        menuBarArt(for: stage).size.width
    }

    /// メニューバー用の単色のテンプレート画像
    static func menuBarImage(for stage: WeightStage) -> NSImage {
        menuBarArt(for: stage)
    }

    /// アニメーションの1コマ。枠の幅はアニメーションの間そろえる
    static func menuBarImage(for frame: CharacterFrame, canvasWidth: CGFloat) -> NSImage {
        let art = menuBarArt(for: frame.stage)
        let image = NSImage(size: NSSize(width: canvasWidth, height: menuBarHeight), flipped: false) { rect in
            let size = NSSize(width: art.size.width * frame.scaleX, height: art.size.height * frame.scaleY)
            NSGraphicsContext.current?.imageInterpolation = .high
            art.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// ポップオーバー用の絵。メニューバーと同じく、体を塗りつぶして線を抜いた単色のテンプレート画像
    static func illustration(for stage: WeightStage) -> NSImage {
        NSImage(named: "Hamster\(stage.rawValue)")!
    }

    /// ポップオーバーの絵の色。`.primary` は半透明で、ダークでは体が灰色に見える
    static let illustrationColor = Color(nsColor: .textColor)

    private static func menuBarArt(for stage: WeightStage) -> NSImage {
        NSImage(named: "MenuBarHamster\(stage.rawValue)")!
    }
}
