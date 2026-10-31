import Foundation

/// キャッシュの削除と起動時の回復（DESIGN.md 8.2）
public struct Purger: Sendable {
    /// 削除しなかった理由
    public enum Skip: Hashable, Sendable {
        case kept
        /// 使うアプリが起動中（7.7）
        case appRunning
        /// 直前の再確認で候補の条件に合わなくなった、または見つからない（8.1）
        case changed
        case failed(SafeFileOps.Failure)

        public var description: String {
            switch self {
            case .kept: "「残す」にした"
            case .appRunning: "アプリが起動中"
            case .changed: "スキャンのあとに変わった"
            case let .failed(failure): failure.description
            }
        }
    }

    public struct Result: Sendable {
        public var moved: [Candidate] = []
        public var skipped: [(candidate: Candidate, reason: Skip)] = []
    }

    public let home: URL
    public var settings: ScanSettings
    private let configuredLocations: [ConfiguredLocation]?
    private let installedApps: [InstalledApp]?

    public init(
        home: URL, settings: ScanSettings = ScanSettings(), configuredLocations: [ConfiguredLocation]? = nil,
        installedApps: [InstalledApp]? = nil
    ) {
        self.home = home
        self.settings = settings
        self.configuredLocations = configuredLocations
        self.installedApps = installedApps
    }

    private var ops: SafeFileOps { SafeFileOps(home: home, configuredLocations: configuredLocations, installedApps: installedApps) }

    /// 候補の条件をもう一度確かめてから `Purge.noindex/` へ移す（8.1・8.2 の 1）。
    /// 渡された候補は ID だけを使い、パスは計画し直した単位から取る
    /// - Parameter runningApps: 起動中のアプリの Bundle ID。呼び出す直前に取り直したもの
    public func moveToPurge(_ candidates: [Candidate], kept: Set<String>, runningApps: Set<String> = [], now: Date = Date()) -> Result {
        // アプリを探すのは1回だけにし、計画と SafeFileOps で同じ結果を使う
        let apps = installedApps ?? AppDiscovery.installedApps(home: home)
        let scanner = Scanner(home: home, settings: settings, configuredLocations: configuredLocations, installedApps: apps)
        let units = Dictionary(scanner.plan().units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ops = SafeFileOps(home: home, configuredLocations: configuredLocations, installedApps: apps)
        var result = Result()

        for candidate in candidates {
            guard !kept.contains(candidate.id) else {
                result.skipped.append((candidate, .kept))
                continue
            }
            guard let unit = units[candidate.id] else {
                result.skipped.append((candidate, .changed))
                continue
            }
            // 画面から渡された候補ではなく、カタログの定義で判定する
            guard runningApps.isDisjoint(with: unit.entry.appBundleIDs) else {
                result.skipped.append((candidate, .appRunning))
                continue
            }
            // 「全体」の単位は日数の条件がないので測り直さない（大きく、測ると時間がかかる）
            if unit.kind != .whole {
                let stats = Scanner.measure(unit)
                guard RuleEngine.candidate(for: unit, stats: stats, settings: settings, home: home, now: now) != nil else {
                    result.skipped.append((candidate, .changed))
                    continue
                }
            }

            let id = UUID()
            do {
                for path in unit.paths {
                    try ops.moveToPurge(path, id: id)
                }
                result.moved.append(candidate)
            } catch {
                // 途中まで移したものは Purge.noindex/ にあり、そのまま削除される
                result.skipped.append((candidate, .failed(error)))
            }
        }
        return result
    }

    /// `Purge.noindex/` の中身を削除する（8.2 の 2・3）。起動時の回復でも呼ぶ
    /// - Returns: 消せなかった項目の数
    @discardableResult
    public func emptyPurge() -> Int {
        ops.emptyPurge()
    }
}
