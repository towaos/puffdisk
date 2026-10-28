import Darwin
import Foundation

/// 測る単位。1つの単位が1つの候補になりうる（DESIGN.md 7.2）
public struct ScanUnit: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// カタログの「全体」の単位
        case whole
        /// カタログの「〜ごと」の単位のサブフォルダ
        case child
        /// DerivedData のプロジェクトごとのフォルダ（7.3）
        case derivedDataProject(DerivedDataProject)
        /// DerivedData の中のプロジェクトではないフォルダをまとめたもの（7.3）
        case sharedXcodeCache
    }

    public let entryID: String
    public let paths: [URL]
    public let kind: Kind
    /// 設定ファイルで指定された場所なら、その設定ファイル
    public let configFile: URL?

    public var id: String { paths.map { $0.path(percentEncoded: false) }.joined(separator: "\n") }

    public var entry: CacheCatalogEntry { CacheCatalog.entries.first { $0.id == entryID }! }
}

/// DerivedData のプロジェクトごとのフォルダの情報（DESIGN.md 7.3）
public struct DerivedDataProject: Hashable, Sendable {
    public enum Workspace: Hashable, Sendable {
        case exists(URL)
        /// ENOENT。元プロジェクトが消えている
        case missing(URL)
        /// `info.plist` がない、権限がない、プライバシー保護の対象などで確かめられない
        case unverifiable(URL?)
    }

    /// `<名前>-<28文字>` の名前の部分
    public let name: String
    public let workspace: Workspace
    /// `Logs/Build` の更新日
    public let lastBuild: Date?
}

/// 走査しなかった場所
public struct SkippedLocation: Hashable, Sendable {
    public let entryID: String
    public let url: URL
    public let reason: LocationRejection
}

public struct ScanPlan: Sendable {
    public var units: [ScanUnit] = []
    public var skipped: [SkippedLocation] = []
}

/// 走査（DESIGN.md 9.3）。`plan` で測る単位を決め（軽い）、`measure` で中身を数える（重い）。
/// サイズのキャッシュがあれば `measure` を飛ばして前回の値で候補を作れる
public struct Scanner: Sendable {
    /// DerivedData のプロジェクトのフォルダ名（`<名前>-<小文字28文字>`）
    static let derivedDataHashLength = 28

    public let home: URL
    public var settings: ScanSettings
    private let policy: ExclusionPolicy
    private let configuredLocations: [ConfiguredLocation]

    public init(home: URL, settings: ScanSettings = ScanSettings(), configuredLocations: [ConfiguredLocation]? = nil) {
        self.home = home
        self.settings = settings
        self.policy = ExclusionPolicy(home: home)
        self.configuredLocations = configuredLocations ?? ToolConfig.configuredLocations(home: home)
    }

    public func plan() -> ScanPlan {
        var plan = ScanPlan()
        for entry in CacheCatalog.entries where !settings.disabledEntries.contains(entry.id) {
            var locations: [(url: URL, configFile: URL?, markers: [String])] =
                entry.resolvedLocations(home: home).map { ($0.standardizedFileURL, nil, []) }
            for configured in configuredLocations where configured.entryID == entry.id {
                let url = configured.url.standardizedFileURL
                if !locations.contains(where: { $0.url == url }) {
                    locations.append((url, configured.configFile, configured.markers))
                }
            }

            for location in locations {
                if let rejection = policy.check(location: location.url, markers: location.markers) {
                    // カタログの既定の場所がないのはふつうなので記録しない
                    if rejection != .notFound || location.configFile != nil {
                        plan.skipped.append(SkippedLocation(entryID: entry.id, url: location.url, reason: rejection))
                    }
                    continue
                }
                switch entry.unit {
                case .whole:
                    plan.units.append(ScanUnit(entryID: entry.id, paths: [location.url], kind: .whole, configFile: location.configFile))
                case .perChild:
                    for child in childDirectories(of: location.url) {
                        plan.units.append(ScanUnit(entryID: entry.id, paths: [child], kind: .child, configFile: location.configFile))
                    }
                case .derivedData:
                    var shared: [URL] = []
                    for child in childDirectories(of: location.url) {
                        if let project = derivedDataProject(at: child) {
                            plan.units.append(ScanUnit(entryID: entry.id, paths: [child], kind: .derivedDataProject(project),
                                                       configFile: location.configFile))
                        } else {
                            shared.append(child)
                        }
                    }
                    if !shared.isEmpty {
                        plan.units.append(ScanUnit(entryID: entry.id, paths: shared, kind: .sharedXcodeCache, configFile: location.configFile))
                    }
                }
            }
        }
        return plan
    }

    /// 単位の中身を数える。複数の場所は別々に数えて足す
    public static func measure(_ unit: ScanUnit) -> TreeStats {
        unit.paths.map(BulkEnumerator.scan).reduce(into: TreeStats()) { $0.merge($1) }
    }

    /// 直下のフォルダ。ファイル、シンボリックリンク、`.` で始まるものは除く（DESIGN.md 7.2）
    func childDirectories(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let child = url.appending(path: name, directoryHint: .isDirectory)
            var info = stat()
            guard lstat(child.path(percentEncoded: false), &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            return child
        }
    }

    /// プロジェクトのフォルダなら情報を返す。名前が `<名前>-<小文字28文字>` でなければ共有キャッシュ（DESIGN.md 7.3）
    func derivedDataProject(at folder: URL) -> DerivedDataProject? {
        let folderName = folder.lastPathComponent
        guard let dash = folderName.lastIndex(of: "-") else { return nil }
        let hash = folderName[folderName.index(after: dash)...]
        guard hash.count == Self.derivedDataHashLength, hash.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }

        var workspace = DerivedDataProject.Workspace.unverifiable(nil)
        if let data = FileManager.default.contents(atPath: folder.appending(path: "info.plist").path(percentEncoded: false)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let path = plist["WorkspacePath"] as? String, path.hasPrefix("/") {
            let url = URL(filePath: path)
            if policy.isPrivacyProtected(url) {
                workspace = .unverifiable(url)
            } else {
                var info = stat()
                if lstat(path, &info) == 0 {
                    workspace = .exists(url)
                } else if errno == ENOENT || errno == ENOTDIR {
                    workspace = .missing(url)
                } else {
                    workspace = .unverifiable(url)
                }
            }
        }

        var lastBuild: Date?
        var info = stat()
        if lstat(folder.appending(path: "Logs/Build").path(percentEncoded: false), &info) == 0 {
            lastBuild = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        }
        return DerivedDataProject(name: String(folderName[..<dash]), workspace: workspace, lastBuild: lastBuild)
    }
}

extension TreeStats {
    mutating func merge(_ other: TreeStats) {
        files += other.files
        directories += other.directories
        symlinks += other.symlinks
        others += other.others
        allocatedBytes += other.allocatedBytes
        reclaimableBytes += other.reclaimableBytes
        errors += other.errors
        if let date = other.latestModification, latestModification.map({ date > $0 }) ?? true {
            latestModification = date
        }
    }
}
