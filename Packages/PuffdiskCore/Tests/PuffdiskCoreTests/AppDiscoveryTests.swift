import Foundation
import Testing
@testable import PuffdiskCore

struct AppDiscoveryTests {
    let fileManager = FileManager.default
    let electron = InstalledApp(bundleID: "md.obsidian", name: "Obsidian", bundleName: "obsidian", isElectron: true)

    func makeApp(in directory: URL, _ name: String, bundleID: String, bundleName: String? = nil, electron: Bool = false) throws {
        let contents = directory.appending(path: "\(name).app/Contents")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let bundleName { plist["CFBundleName"] = bundleName }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        if electron {
            try fileManager.createDirectory(at: contents.appending(path: "Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
        }
    }

    @Test func findsAppsAndElectronFramework() throws {
        let home = try TestHome()
        defer { home.remove() }
        let applications = try home.directory("Applications")
        try makeApp(in: applications, "Obsidian", bundleID: "md.obsidian", bundleName: "obsidian", electron: true)
        try makeApp(in: applications, "Native", bundleID: "com.example.native")
        // /Applications/Setapp/ のような1階層下のフォルダ
        try makeApp(in: applications.appending(path: "Setapp"), "Nested", bundleID: "com.example.nested")
        try home.file("Applications/Broken.app/Contents/Info.plist", contents: Data("x".utf8))

        let apps = AppDiscovery.installedApps(in: [applications])
        #expect(apps.map(\.bundleID).sorted() == ["com.example.native", "com.example.nested", "md.obsidian"])
        #expect(apps.first { $0.bundleID == "md.obsidian" } == electron)
        // CFBundleName がなければファイル名
        #expect(apps.first { $0.bundleID == "com.example.native" }?.bundleName == "Native")
        #expect(apps.first { $0.bundleID == "com.example.native" }?.isElectron == false)
    }

    @Test func electronAppsGetCachesUpdatesAndShipIt() throws {
        let entry = try #require(AppDiscovery.entries(for: [electron]).first)
        #expect(entry.id == "app:md.obsidian")
        #expect(entry.name == "Obsidian")
        #expect(entry.unit == .combined)
        #expect(entry.appBundleIDs == ["md.obsidian"])
        #expect(entry.paths.contains("Library/Application Support/obsidian/Cache"))
        #expect(!entry.paths.contains("Library/Application Support/obsidian/Local Storage"))
        #expect(entry.paths.suffix(2) == ["Library/Caches/obsidian-updater", "Library/Caches/md.obsidian.ShipIt"])
    }

    @Test func otherAppsGetOnlyShipIt() throws {
        let native = InstalledApp(bundleID: "com.example.native", name: "Native", bundleName: "Native", isElectron: false)
        let entry = try #require(AppDiscovery.entries(for: [native]).first)
        #expect(entry.paths == ["Library/Caches/com.example.native.ShipIt"])
        #expect(entry.reason == CacheCatalog.updateReason)
    }

    @Test func skipsAppleCatalogAndUnsafeNames() {
        let apps = [
            InstalledApp(bundleID: "com.apple.Safari", name: "Safari", bundleName: "Safari", isElectron: false),
            // カタログに載っているアプリは、カタログの項目を使う
            InstalledApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", bundleName: "Slack", isElectron: true),
            InstalledApp(bundleID: "com.example.bad", name: "Bad", bundleName: "../Bad", isElectron: true),
            InstalledApp(bundleID: "com.example.dot", name: "Dot", bundleName: ".hidden", isElectron: true),
        ]
        #expect(AppDiscovery.entries(for: apps).isEmpty)
    }

    @Test func doesNotReuseCatalogLocations() throws {
        // Bundle ID は違うが、名前がカタログのアプリと同じ
        let other = InstalledApp(bundleID: "com.example.slack", name: "Slack 2", bundleName: "Slack", isElectron: true)
        let entry = try #require(AppDiscovery.entries(for: [other]).first)
        #expect(!entry.paths.contains("Library/Application Support/Slack/Cache"))
        #expect(entry.paths.contains("Library/Caches/com.example.slack.ShipIt"))
    }

    @Test func scannerAndPurgerUseDiscoveredApps() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file("Library/Application Support/obsidian/Cache/a", bytes: 4096)
        try home.file("Library/Application Support/obsidian/Local Storage/b", bytes: 4096)
        try home.file("Library/Caches/md.obsidian.ShipIt/update.x/c", bytes: 4096)

        let scanner = Scanner(home: home.url, configuredLocations: [], installedApps: [electron])
        let unit = try #require(scanner.plan().units.first { $0.entryID == "app:md.obsidian" })
        #expect(unit.paths.map(\.lastPathComponent) == ["Cache", "md.obsidian.ShipIt"])
        var stats = Scanner.measure(unit)
        stats.reclaimableBytes = 500_000_000
        let candidate = try #require(RuleEngine.candidate(for: unit, stats: stats, settings: scanner.settings, home: home.url))
        #expect(candidate.title == "Obsidian")
        #expect(candidate.appBundleIDs == ["md.obsidian"])

        let purger = Purger(home: home.url, configuredLocations: [], installedApps: [electron])
        #expect(purger.moveToPurge([candidate], kept: [], runningApps: ["md.obsidian"]).skipped.map(\.reason) == [.appRunning])
        // アンインストールされたら、残りのフォルダは対象にしない
        #expect(Purger(home: home.url, configuredLocations: [], installedApps: []).moveToPurge([candidate], kept: [])
            .skipped.map(\.reason) == [.changed])

        #expect(purger.moveToPurge([candidate], kept: []).moved.count == 1)
        #expect(!fileManager.fileExists(atPath: home.path("Library/Application Support/obsidian/Cache").path(percentEncoded: false)))
        #expect(fileManager.fileExists(atPath: home.path("Library/Application Support/obsidian/Local Storage/b").path(percentEncoded: false)))
    }
}
