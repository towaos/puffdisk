import Foundation

/// インストールされているアプリ（DESIGN.md 7.8）。`Info.plist` だけを読む
public struct InstalledApp: Hashable, Sendable {
    public let bundleID: String
    /// 一覧に出す名前
    public let name: String
    /// `CFBundleName`。Electron アプリはこの名前で `~/Library/Application Support/<名前>/` を作る
    public let bundleName: String
    /// `Contents/Frameworks/Electron Framework.framework` がある
    public let isElectron: Bool

    public init(bundleID: String, name: String, bundleName: String, isElectron: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.bundleName = bundleName
        self.isElectron = isElectron
    }
}

/// カタログに載っていないアプリのキャッシュを、決まった目印で見つける（DESIGN.md 7.8）。
/// 見つけたアプリごとに「まとめて」の項目を作る。対象のフォルダ名はカタログの Electron アプリと同じ
public enum AppDiscovery {
    /// アプリを探す場所。直下の `.app` と、その1階層下（`/Applications/Setapp/` など）の `.app`
    public static func applicationDirectories(home: URL) -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    public static func installedApps(home: URL) -> [InstalledApp] {
        installedApps(in: applicationDirectories(home: home))
    }

    static func installedApps(in directories: [URL]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for directory in directories {
            for child in children(of: directory) {
                if child.pathExtension == "app" {
                    if let app = app(at: child) { apps.append(app) }
                } else {
                    apps += children(of: child).filter { $0.pathExtension == "app" }.compactMap(app(at:))
                }
            }
        }
        var seen: Set<String> = []
        return apps.filter { seen.insert($0.bundleID).inserted }
    }

    static func app(at url: URL) -> InstalledApp? {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        guard let data = FileManager.default.contents(atPath: contents.appending(path: "Info.plist").path(percentEncoded: false)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let bundleName = plist["CFBundleName"] as? String ?? fileName
        // CFBundleName は小文字のこともあるので、Finder に出るファイル名を使う
        let name = plist["CFBundleDisplayName"] as? String ?? fileName
        let framework = contents.appending(path: "Frameworks/Electron Framework.framework").path(percentEncoded: false)
        return InstalledApp(bundleID: bundleID, name: name, bundleName: bundleName, isElectron: FileManager.default.fileExists(atPath: framework))
    }

    /// カタログに載っていないアプリの項目。Apple のアプリと、カタログに同じ Bundle ID か場所があるものは作らない
    public static func entries(for apps: [InstalledApp]) -> [CacheCatalogEntry] {
        let catalogIDs = Set(CacheCatalog.entries.flatMap(\.appBundleIDs))
        let catalogPaths = Set(CacheCatalog.entries.flatMap(\.paths).map { $0.lowercased() })
        return apps.compactMap { app in
            guard !app.bundleID.hasPrefix("com.apple."), !catalogIDs.contains(app.bundleID),
                  isSafeName(app.bundleID), isSafeName(app.bundleName) else { return nil }
            var paths: [String] = []
            if app.isElectron {
                paths += CacheCatalog.electronCaches("Library/Application Support/\(app.bundleName)")
                paths.append("Library/Caches/\(app.bundleName)-updater")
            }
            paths.append("Library/Caches/\(app.bundleID).ShipIt")

            // 同じ Purge.noindex/<ID>/ に並べるので、最後の要素が重なるもの（APFS は大文字・小文字を区別しない）は外す
            var names: Set<String> = []
            paths = paths.filter { path in
                !catalogPaths.contains(path.lowercased()) && names.insert(path.split(separator: "/").last!.lowercased()).inserted
            }
            return CacheCatalogEntry(
                id: "app:\(app.bundleID)", name: app.name, group: "アプリ", paths: paths, unit: .combined,
                appBundleIDs: [app.bundleID], reason: app.isElectron ? CacheCatalog.appReason : CacheCatalog.updateReason)
        }
    }

    /// パスの1要素として使える名前。`/`・`*` を含むもの、`.` で始まるものは使わない
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("*") && !name.contains("\0")
    }

    private static func children(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { directory.appending(path: $0, directoryHint: .isDirectory) }
    }
}
