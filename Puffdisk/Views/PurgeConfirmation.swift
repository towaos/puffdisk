import PuffdiskCore
import SwiftUI

/// 削除の確認シート（DESIGN.md 6.1・8.2）。対象と合計を出す
struct PurgeConfirmation: View {
    let candidates: [Candidate]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var total: Int64 { candidates.reduce(0) { $0 + $1.reclaimableBytes } }

    static func targetDescription(_ candidate: Candidate) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let first = RuleEngine.displayPath(candidate.paths[0], home: home)
        return candidate.paths.count == 1 ? first : "\(first) ほか \(candidate.paths.count - 1) 件"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Formatting.bytes(total)) のキャッシュを削除しますか？")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { candidate in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.title)
                                // 一覧の detail は元プロジェクトの場所のことがあるので、ここでは実際に消す場所を出す
                                Text(Self.targetDescription(candidate))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(Formatting.bytes(candidate.reclaimableBytes))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Label("元に戻せません。必要になったときに、各ツールが取り直します", systemImage: "exclamationmark.triangle")
                Label("実行中のビルドやインストールは失敗することがあります", systemImage: "hammer")
                if candidates.contains(where: { !$0.defaultSelected }) {
                    Label("取り直すのに時間がかかるものが含まれています", systemImage: "clock")
                }
                Label(Formatting.estimateNote, systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("削除", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
