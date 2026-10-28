import Foundation

/// 判定に使う日数（DESIGN.md 7.6）。設定画面は M5
public struct ScanSettings: Equatable, Sendable {
    /// 「〜ごと」の単位で、これより新しく更新されたものは候補にしない（7.5）
    public var recentDays = 7
    /// DerivedData の未ビルド日数（7.3）
    public var derivedDataDays = 30
    /// DeviceSupport・JetBrains の未更新日数（7.2）
    public var staleToolDataDays = 90
    /// オフにしたカタログの種類（走査もしない）
    public var disabledEntries: Set<String> = []

    public init() {}
}

/// 候補の理由（DESIGN.md 10.1）
public enum CandidateReason: Hashable, Sendable {
    /// カタログの理由文
    case refetchable(String)
    case workspaceMissing
    case workspaceUnverifiable
    case notBuilt(days: Int)
    case notUpdated(days: Int)
    case sharedXcodeCache
    /// 設定ファイルで指定された場所（表示用のパス）
    case configured(String)
    /// 一部のファイルを読めず、サイズが少なめ
    case partiallyUnreadable

    public var text: String {
        switch self {
        case let .refetchable(text): text
        case .workspaceMissing: "元プロジェクトが存在しない"
        case .workspaceUnverifiable: "元プロジェクトがあるか確認できない"
        case let .notBuilt(days): "\(days)日間ビルドされていない。次回ビルドで作り直される"
        case let .notUpdated(days): "\(days)日間更新されていない"
        case .sharedXcodeCache: "Xcode が共有で使うキャッシュ。必要に応じて作り直される"
        case let .configured(file): "\(file) で指定された場所"
        case .partiallyUnreadable: "読めないファイルがあり、実際はもう少し大きい"
        }
    }
}

/// 候補（DESIGN.md 10.1）。スキャンごとに作り直し、保存しない
public struct Candidate: Identifiable, Hashable, Sendable {
    /// 判定に使った日付と、その種類（DESIGN.md 10.1）
    public struct LastUsed: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case modified
            case built
        }

        public let date: Date
        public let kind: Kind
    }

    public let unitID: String
    public let entryID: String
    public let group: String
    public let title: String
    /// 場所の表示（`~/` 始まり）。DerivedData のプロジェクトは元プロジェクトの場所（「元: 」付き）
    public let detail: String
    public let paths: [URL]
    public let reclaimableBytes: Int64
    public let category: CandidateCategory
    public let defaultSelected: Bool
    public let reasons: [CandidateReason]
    /// 判定に使った日付。「全体」の単位はなし
    public let lastUsed: LastUsed?

    public var id: String { unitID }
}

/// 走査結果 → 候補＋理由（DESIGN.md 7.2・7.3）。ファイルを読まない
public enum RuleEngine {
    /// Xcode 共有キャッシュを候補にする下限（7.3）
    public static let sharedXcodeCacheMinimumBytes: Int64 = 100_000_000

    public static func candidate(
        for unit: ScanUnit, stats: TreeStats, settings: ScanSettings, home: URL, now: Date = Date()
    ) -> Candidate? {
        guard stats.reclaimableBytes > 0 else { return nil }
        let entry = unit.entry
        let path = unit.paths.count == 1 ? unit.paths[0] : unit.paths[0].deletingLastPathComponent()
        var title = entry.name
        var detail = displayPath(path, home: home)
        var reasons: [CandidateReason] = []
        var lastUsed: Candidate.LastUsed?

        func isRecent(_ date: Date?) -> Bool {
            guard let date else { return false }
            return days(from: date, to: now) < settings.recentDays
        }

        switch unit.kind {
        case .whole:
            guard stats.reclaimableBytes >= entry.minimumBytes else { return nil }
            reasons = [.refetchable(entry.reason)]

        case .child:
            guard !isRecent(stats.latestModification), stats.reclaimableBytes >= entry.minimumBytes else { return nil }
            title = childTitle(unit.paths[0], entryID: entry.id)
            if let modified = stats.latestModification { lastUsed = .init(date: modified, kind: .modified) }
            switch entry.ageRule {
            case .staleToolData:
                guard let modified = stats.latestModification else { return nil }
                let elapsed = days(from: modified, to: now)
                guard elapsed >= settings.staleToolDataDays else { return nil }
                reasons = [.notUpdated(days: elapsed), .refetchable(entry.reason)]
            case nil:
                reasons = [.refetchable(entry.reason)]
            }

        case let .derivedDataProject(project):
            guard !isRecent(stats.latestModification), stats.reclaimableBytes >= entry.minimumBytes else { return nil }
            title = project.name
            let built = project.lastBuild ?? stats.latestModification
            if let built { lastUsed = .init(date: built, kind: project.lastBuild == nil ? .modified : .built) }
            switch project.workspace {
            case let .missing(workspace):
                detail = "元: " + displayPath(workspace, home: home)
                reasons = [.workspaceMissing, .refetchable(entry.reason)]
            case let .exists(workspace), let .unverifiable(workspace?):
                detail = "元: " + displayPath(workspace, home: home)
                fallthrough
            case .unverifiable(nil):
                guard let built else { return nil }
                let elapsed = days(from: built, to: now)
                guard elapsed >= settings.derivedDataDays else { return nil }
                reasons = [.notBuilt(days: elapsed)]
                if case .unverifiable = project.workspace { reasons.append(.workspaceUnverifiable) }
            }

        case .sharedXcodeCache:
            guard stats.reclaimableBytes >= sharedXcodeCacheMinimumBytes else { return nil }
            title = "Xcode 共有キャッシュ"
            reasons = [.sharedXcodeCache]
        }

        if let configFile = unit.configFile {
            reasons.append(.configured(displayPath(configFile, home: home)))
        }
        if stats.errors > 0 {
            reasons.append(.partiallyUnreadable)
        }
        return Candidate(
            unitID: unit.id, entryID: entry.id, group: entry.group, title: title, detail: detail, paths: unit.paths,
            reclaimableBytes: stats.reclaimableBytes, category: entry.category, defaultSelected: entry.selectedByDefault,
            reasons: reasons, lastUsed: lastUsed
        )
    }

    /// 経過日数（切り捨て）
    static func days(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// Hugging Face の `models--org--name` は `org/name` にする
    static func childTitle(_ url: URL, entryID: String) -> String {
        let name = url.lastPathComponent
        guard entryID == "huggingface" else { return name }
        let parts = name.components(separatedBy: "--")
        guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]) else { return name }
        return parts.dropFirst().joined(separator: "/")
    }

    public static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let homePath = home.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
