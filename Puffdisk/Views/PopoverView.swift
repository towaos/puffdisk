import AppKit
import SwiftUI

/// ポップオーバーの枠（DESIGN.md 6.1）。候補一覧は M1
struct PopoverView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            #if DEBUG
            DebugPanel(state: state)
            #else
            Text("候補一覧（M1）")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            Divider()
            footer
        }
        .frame(width: 360, height: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: CharacterRenderer.image(for: state.stage, height: 56))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 70, height: 56)
                .accessibilityLabel("段階 \(state.stage.rawValue)")
            VStack(alignment: .leading, spacing: 6) {
                Text("消せそうな量 —")
                    .font(.headline)
                DiskUsageBar()
                Text("最終スキャン —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Text("隔離中 0件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("選択した 0 GB を削除") {}
                .disabled(true)
            Menu {
                Button("設定…") {}
                    .disabled(true)
                Divider()
                Button("Puffdisk を終了") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("メニュー")
        }
        .padding(12)
    }
}

/// 起動ディスクの使用量
private struct DiskUsageBar: View {
    private let usage: (used: Int64, total: Int64)? = {
        let values = try? URL(filePath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total) - available, Int64(total))
    }()

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(usage.used), total: Double(usage.total))
                Text("使用 \(format(usage.used)) / \(format(usage.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
