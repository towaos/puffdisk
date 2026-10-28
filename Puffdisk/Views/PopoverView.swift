import AppKit
import PuffdiskCore
import SwiftUI

/// ポップオーバーからの操作
struct PopoverActions {
    var rescan: () -> Void
    var purge: ([Candidate]) -> Void
    var keep: (Candidate) -> Void
    var unkeep: (String) -> Void
}

/// ポップオーバー（DESIGN.md 6.1）
struct PopoverView: View {
    let state: AppState
    let actions: PopoverActions
    @State private var category = CandidateCategory.cache
    @State private var showsDebug = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = state.notice {
                NoticeBar(text: notice) { state.notice = nil }
            }
            Divider()
            #if DEBUG
            if showsDebug {
                DebugPanel(state: state)
            } else {
                content
            }
            #else
            content
            #endif
            Divider()
            footer
        }
        .frame(width: 360, height: 520)
        .overlay {
            if let confirming = state.confirmingPurge {
                PurgeConfirmation(candidates: confirming) {
                    state.confirmingPurge = nil
                } onConfirm: {
                    state.confirmingPurge = nil
                    actions.purge(confirming)
                }
            }
        }
    }

    private var selectedCandidates: [Candidate] { state.selectedCandidates(in: category) }

    // MARK: - 上部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: CharacterRenderer.image(for: state.stage, height: 56))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 70, height: 56)
                .accessibilityLabel("段階 \(state.stage.rawValue)")
            VStack(alignment: .leading, spacing: 6) {
                Text("消せそうな量 \(Formatting.bytes(state.reclaimableBytes))")
                    .font(.headline)
                    .help(Formatting.estimateNote)
                DiskUsageBar()
                scanLine
            }
        }
        .padding(14)
    }

    private var scanLine: some View {
        HStack(spacing: 6) {
            switch state.scanStatus {
            case let .scanning(done, total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("スキャン中 \(done)/\(total)")
            case .idle:
                if let lastScan = state.lastScan {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("最終スキャン \(Formatting.relative(lastScan))")
                            .id(context.date)
                    }
                } else {
                    Text("最終スキャン —")
                }
                Button(action: actions.rescan) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("再スキャン")
                .accessibilityLabel("再スキャン")
            }
            if state.purgeStatus == .deleting {
                Text("・削除中…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - 一覧

    @ViewBuilder
    private var content: some View {
        if state.candidates.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $category) {
                    Text("キャッシュ \(Formatting.bytes(state.total(of: .cache)))").tag(CandidateCategory.cache)
                    Text("要確認 \(Formatting.bytes(state.total(of: .review)))").tag(CandidateCategory.review)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                CandidateList(state: state, category: category, keep: actions.keep)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if case .scanning = state.scanStatus {
                ProgressView()
                Text("キャッシュを探しています…")
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: CharacterRenderer.image(for: .one, height: 48))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                Text("すっきり！")
                    .font(.title3)
                Text("消せそうなキャッシュはありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 下部

    private var footer: some View {
        HStack {
            Text("隔離中 0件")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            let selectedBytes = Formatting.bytes(state.selectedBytes(in: category))
            if category == .cache {
                Button("選択した \(selectedBytes) を削除") { state.confirmingPurge = selectedCandidates }
                    .disabled(selectedCandidates.isEmpty || state.scanStatus != .idle || state.purgeStatus == .moving)
                    .help(state.scanStatus != .idle ? "スキャンが終わると削除できます" : "")
            } else {
                // 隔離は M3
                Button("選択した \(selectedBytes) を隔離") {}
                    .disabled(true)
            }
            Menu {
                Button("再スキャン", action: actions.rescan)
                    .disabled(state.scanStatus != .idle)
                keptMenu
                Button("設定…") {}
                    .disabled(true)
                #if DEBUG
                Toggle("デバッグ画面", isOn: $showsDebug)
                #endif
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

extension PopoverView {
    /// 「残す」にしたもの。設定画面（M5）ができるまではここから戻す
    @ViewBuilder
    private var keptMenu: some View {
        if state.keptItems.isEmpty {
            Button("残したもの（なし）") {}
                .disabled(true)
        } else {
            Menu("残したもの（\(state.keptItems.count)件）") {
                Section("選ぶと候補に戻します") {
                    ForEach(state.keptItems) { item in
                        Button(item.title) { actions.unkeep(item.id) }
                    }
                }
            }
        }
    }
}

private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("閉じる")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }
}

/// 表示の書式。画面は日本語だけなので、システムの言語設定によらず日本語で出す
enum Formatting {
    static let locale = Locale(identifier: "ja_JP")
    static let estimateNote = "空く見込みの量です。APFS のクローンやスナップショットがあると、実際に空く量は少なくなることがあります"

    static func bytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(locale))
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
                Text("使用 \(Formatting.bytes(usage.used)) / \(Formatting.bytes(usage.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
