#if DEBUG
import PuffdiskCore
import SwiftUI

/// M0 のデバッグ画面: 段階の切り替え
struct DebugPanel: View {
    let state: AppState
    @State private var treatAsUserAction = false

    private let gb = Double(WeightCalculator.gigabyte)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stageSection
            }
            .padding(14)
        }
    }

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("デバッグ: 段階").font(.subheadline.bold())

            let fullLine = Double(state.calculator.fullLine)
            LabeledContent("スコア \(String(format: "%.1f", Double(state.score) / gb)) GB → 段階 \(state.stage.rawValue)") {}
            Slider(
                value: Binding(
                    get: { Double(state.score) },
                    set: { state.updateScore(Int64($0), userAction: treatAsUserAction) }
                ),
                in: 0...(fullLine * 1.2)
            )
            Toggle("削除の直後として扱う（ちらつき防止なし）", isOn: $treatAsUserAction)
                .font(.caption)

            LabeledContent("満腹ライン \(Int(fullLine / gb)) GB") {}
            Slider(
                value: Binding(
                    get: { fullLine / gb },
                    set: { state.updateFullLine(Int64($0.rounded()) * WeightCalculator.gigabyte) }
                ),
                in: 5...500
            )
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(WeightStage.allCases, id: \.self) { stage in
                    GridRow {
                        Text("段階 \(stage.rawValue)")
                        Text(String(format: "%.1f GB 〜", Double(state.calculator.lowerBound(of: stage)) / gb))
                            .foregroundStyle(stage == state.stage ? .primary : .secondary)
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }
}
#endif
