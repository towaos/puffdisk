import Darwin
import Foundation

/// 走査しない理由（DESIGN.md 7.5）
public enum LocationRejection: Hashable, Sendable {
    case notFound
    case outsideHome
    /// ホームそのもの、または標準のフォルダ・他のカタログの場所・触らないものを含む
    case containsImportantFolder(String)
    /// 触らないもの（7.2）やアプリ自身のフォルダの中
    case protectedLocation(String)
    /// Desktop・Documents・Downloads など。読むと macOS の許可ダイアログが出る
    case privacyProtected
    case symbolicLinkInPath(String)
    case differentVolume
    case insideProject(String)
    case cloudSynced
    /// 設定ファイルで指定された場所に、そのツールの目印がない
    case markerMissing

    public var description: String {
        switch self {
        case .notFound: "存在しない"
        case .outsideHome: "ホームフォルダの外"
        case let .containsImportantFolder(path): "大事なフォルダ（\(path)）を含む"
        case let .protectedLocation(path): "触らない場所（\(path)）の中"
        case .privacyProtected: "macOS のプライバシー保護の対象"
        case let .symbolicLinkInPath(path): "途中にシンボリックリンクがある（\(path)）"
        case .differentVolume: "ホームと別のボリューム"
        case let .insideProject(path): "プロジェクトの中（\(path)）"
        case .cloudSynced: "クラウド同期の対象"
        case .markerMissing: "ツールのキャッシュの目印がない"
        }
    }
}

/// 触らないものの判定（DESIGN.md 7.5）。M1 ではカタログの場所の検証だけを行う。
/// 一般ファイルの対象フォルダの検証（6.4）は M3
public struct ExclusionPolicy: Sendable {
    /// プロジェクトの目印（7.5）
    public static let projectMarkers: Set<String> = [
        ".git", "package.json", "pyproject.toml", "requirements.txt", "Pipfile", "Cargo.toml", "Package.swift",
        "go.mod", "Gemfile", "build.gradle", "build.gradle.kts", "pom.xml",
    ]
    public static let projectMarkerExtensions: Set<String> = ["xcodeproj", "xcworkspace"]
    /// 同期ツールの目印（7.5）
    public static let syncMarkers: Set<String> = [".dropbox", ".stfolder"]

    /// 中を読むと macOS の許可ダイアログ（TCC）が出る場所
    public static let privacyProtectedPaths = ["Desktop", "Documents", "Downloads"]
    /// 含んでいてはいけない、ホーム直下の標準のフォルダ
    public static let importantPaths = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications",
        "Developer", ".ssh", ".gnupg", ".config",
    ]
    /// 中に入ってはいけない場所
    public static let protectedPaths = CacheCatalog.protectedPaths + [
        "Library/Application Support/Puffdisk", "Library/CloudStorage", "Library/Mobile Documents",
    ]

    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// カタログの場所を走査してよいか
    /// - Parameter markers: 設定ファイルで指定された場所のときの、ツールの目印
    public func check(location: URL, markers: [String] = []) -> LocationRejection? {
        guard let relative = relativeComponents(of: location) else { return .outsideHome }
        let relativePath = relative.joined(separator: "/")

        if relative.isEmpty { return .containsImportantFolder("~") }
        // 他のカタログの場所を含むもの（例: 設定で `~/.cache` を指定）も拒否する。自分自身と同じ場所は除く
        let mustNotContain = Self.importantPaths + Self.protectedPaths
            + CacheCatalog.entries.flatMap(\.paths).filter { !Self.isWithin(relativePath, $0) }
        if let inside = Self.importantPaths.first(where: { $0 == relativePath })
            ?? mustNotContain.first(where: { Self.isWithin($0, relativePath) && $0 != relativePath }) {
            return .containsImportantFolder("~/" + inside)
        }
        if let protected = Self.protectedPaths.first(where: { Self.isWithin(relativePath, $0) }) {
            return .protectedLocation("~/" + protected)
        }
        if Self.privacyProtectedPaths.contains(where: { Self.isWithin(relativePath, $0) }) {
            return .privacyProtected
        }

        // ホームの下を1階層ずつ lstat で確かめる
        var current = home
        for name in relative {
            current = current.appending(path: name)
            var info = stat()
            guard lstat(current.path(percentEncoded: false), &info) == 0 else { return .notFound }
            if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLinkInPath("~/" + displayRelative(current)) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return .notFound }
        }

        if volumeID(of: location) != volumeID(of: home) { return .differentVolume }
        if let values = try? location.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return .cloudSynced
        }

        // 自分自身と、ホームより下の祖先に目印がないこと。ホーム直下の `~/.git`（dotfiles 管理）は見ない
        var ancestor = home
        for name in relative {
            ancestor = ancestor.appending(path: name)
            let children = Set((try? FileManager.default.contentsOfDirectory(atPath: ancestor.path(percentEncoded: false))) ?? [])
            if !children.isDisjoint(with: Self.syncMarkers) { return .cloudSynced }
            if !children.isDisjoint(with: Self.projectMarkers)
                || children.contains(where: { Self.projectMarkerExtensions.contains(($0 as NSString).pathExtension) }) {
                return .insideProject("~/" + displayRelative(ancestor))
            }
        }

        if !markers.isEmpty {
            let children = Set((try? FileManager.default.contentsOfDirectory(atPath: location.path(percentEncoded: false))) ?? [])
            if children.isDisjoint(with: markers) { return .markerMissing }
        }
        return nil
    }

    /// Desktop・Documents・Downloads の中か。中を確かめると許可ダイアログが出るので、確かめずに扱う
    public func isPrivacyProtected(_ url: URL) -> Bool {
        guard let relative = relativeComponents(of: url) else {
            // 外付けディスクも許可ダイアログの対象
            return url.standardizedFileURL.path(percentEncoded: false).hasPrefix("/Volumes/")
        }
        let path = relative.joined(separator: "/")
        return (Self.privacyProtectedPaths + ["Library/Mobile Documents", "Library/CloudStorage"])
            .contains { Self.isWithin(path, $0) }
    }

    /// ホームからの相対パスの要素。ホームの外なら nil
    func relativeComponents(of url: URL) -> [String]? {
        let homeComponents = home.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= homeComponents.count,
              Array(components.prefix(homeComponents.count)) == homeComponents,
              !components.contains("..") else { return nil }
        return Array(components.dropFirst(homeComponents.count))
    }

    private func displayRelative(_ url: URL) -> String {
        relativeComponents(of: url)?.joined(separator: "/") ?? url.path(percentEncoded: false)
    }

    private func volumeID(of url: URL) -> dev_t? {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 ? info.st_dev : nil
    }

    /// `path` が `base`（1つの要素に `*` を含みうる）と同じか、その中にあるか
    public static func isWithin(_ path: String, _ base: String) -> Bool {
        let pathComponents = path.split(separator: "/")
        let baseComponents = base.split(separator: "/")
        guard pathComponents.count >= baseComponents.count else { return false }
        return zip(pathComponents, baseComponents).allSatisfy { name, pattern in
            guard pattern.contains("*") else { return name == pattern }
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
            return name.count >= parts[0].count + parts[parts.count - 1].count
                && name.hasPrefix(parts[0]) && name.hasSuffix(parts[parts.count - 1])
        }
    }
}
