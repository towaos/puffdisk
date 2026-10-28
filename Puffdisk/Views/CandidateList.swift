import AppKit
import PuffdiskCore
import SwiftUI

/// 候補一覧。種類ごとにまとめる（DESIGN.md 6.1）
struct CandidateList: View {
    let state: AppState
    let category: CandidateCategory
    @State private var collapsed: Set<String> = []

    private var groups: [(name: String, candidates: [Candidate])] {
        var result: [(name: String, candidates: [Candidate])] = []
        for candidate in state.candidates where candidate.category == category {
            if let index = result.firstIndex(where: { $0.name == candidate.group }) {
                result[index].candidates.append(candidate)
            } else {
                result.append((candidate.group, [candidate]))
            }
        }
        return result
    }

    var body: some View {
        let groups = groups
        if groups.isEmpty {
            Text(category == .cache ? "消せそうなキャッシュはありません" : "要確認の候補はありません")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.name) { group in
                        groupHeader(group.name, total: group.candidates.reduce(0) { $0 + $1.reclaimableBytes })
                        if !collapsed.contains(group.name) {
                            ForEach(group.candidates) { candidate in
                                CandidateRow(candidate: candidate, isSelected: binding(for: candidate))
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func groupHeader(_ name: String, total: Int64) -> some View {
        Button {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(collapsed.contains(name) ? 0 : 90))
                    .font(.caption2.bold())
                    .frame(width: 12)
                Text(name)
                Spacer()
                Text(Formatting.bytes(total))
                    .monospacedDigit()
            }
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityLabel("\(name) \(Formatting.bytes(total))")
        .accessibilityValue(collapsed.contains(name) ? "閉じている" : "開いている")
    }

    private func binding(for candidate: Candidate) -> Binding<Bool> {
        Binding(
            get: { state.selection.contains(candidate.id) },
            set: { isOn in
                if isOn { state.selection.insert(candidate.id) } else { state.selection.remove(candidate.id) }
            }
        )
    }
}

private struct CandidateRow: View {
    let candidate: Candidate
    @Binding var isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(candidate.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if isHovering {
                        Button(action: reveal) {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Finder で表示")
                        .accessibilityLabel("Finder で表示")
                    }
                    Text(Formatting.bytes(candidate.reclaimableBytes))
                        .monospacedDigit()
                        .help(Formatting.estimateNote)
                }
                ForEach(candidate.reasons, id: \.self) { reason in
                    Text(reason.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(candidate.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.detail)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Finder で表示", action: reveal)
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(candidate.paths)
    }
}
