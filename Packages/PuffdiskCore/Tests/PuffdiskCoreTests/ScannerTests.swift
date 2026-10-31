import Foundation
import Testing
@testable import PuffdiskCore

struct ScannerTests {
    static let hash = String(repeating: "a", count: 27) + "z"

    func makeHome() throws -> TestHome {
        let home = try TestHome()
        try home.file(".npm/_cacache/content-v2/a", bytes: 4096)
        try home.file(".cache/huggingface/hub/version.txt")
        try home.file(".cache/huggingface/hub/models--org--model/blob", bytes: 4096)
        try home.directory(".cache/huggingface/hub/.locks/models--org--model")

        let derivedData = "Library/Developer/Xcode/DerivedData"
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": home.path("Developer/Gone/Gone.xcodeproj").path(percentEncoded: false)],
            format: .xml, options: 0)
        try home.file("\(derivedData)/Gone-\(Self.hash)/info.plist", contents: plist)
        try home.directory("\(derivedData)/Gone-\(Self.hash)/Logs/Build")
        let privatePlist = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": home.path("Documents/App/App.xcodeproj").path(percentEncoded: false)],
            format: .xml, options: 0)
        try home.file("\(derivedData)/App-\(Self.hash)/info.plist", contents: privatePlist)
        // info.plist がないプロジェクトのフォルダもある（M1 で実機確認）
        try home.file("\(derivedData)/Pods-\(Self.hash)/Build/x", bytes: 4096)
        try home.file("\(derivedData)/ModuleCache.noindex/a.pcm", bytes: 4096)
        try home.file("\(derivedData)/SymbolCache.noindex/b", bytes: 4096)

        // カタログの場所の近くにある、触らないもの（DESIGN.md 7.2）
        try home.file(".cargo/bin/cargo", bytes: 4096)
        try home.file(".cargo/config.toml")
        try home.file(".cargo/registry/cache/index/crate.crate", bytes: 4096)
        try home.file(".gradle/gradle.properties")
        try home.file(".gradle/caches/modules-2/x", bytes: 4096)
        try home.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/dSYM", bytes: 4096)
        try home.file("Library/Developer/CoreSimulator/Devices/UUID/data/app", bytes: 4096)
        try home.file("Library/Developer/CoreSimulator/Caches/dyld/x", bytes: 4096)
        return home
    }

    func paths(_ plan: ScanPlan, _ home: TestHome) -> [String] {
        plan.units.flatMap(\.paths).map { RuleEngine.displayPath($0, home: home.url) }
    }

    @Test func plansUnitsPerCatalogUnit() throws {
        let home = try makeHome()
        defer { home.remove() }
        let plan = Scanner(home: home.url, configuredLocations: [], installedApps: []).plan()

        #expect(paths(plan, home).sorted() == [
            "~/.cache/huggingface/hub/models--org--model",
            "~/.cargo/registry/cache",
            "~/.gradle/caches",
            "~/.npm/_cacache",
            "~/Library/Developer/CoreSimulator/Caches",
            "~/Library/Developer/Xcode/DerivedData/App-\(Self.hash)",
            "~/Library/Developer/Xcode/DerivedData/Gone-\(Self.hash)",
            "~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex",
            "~/Library/Developer/Xcode/DerivedData/Pods-\(Self.hash)",
            "~/Library/Developer/Xcode/DerivedData/SymbolCache.noindex",
        ])
        #expect(plan.skipped.isEmpty)

        let shared = try #require(plan.units.first { $0.kind == .sharedXcodeCache })
        #expect(shared.paths.count == 2)
    }

    @Test func protectedPathsNeverBecomeUnits() throws {
        let home = try makeHome()
        defer { home.remove() }
        let plan = Scanner(home: home.url, configuredLocations: [], installedApps: []).plan()

        for unitPath in paths(plan, home) {
            for protected in CacheCatalog.protectedPaths {
                #expect(!ExclusionPolicy.isWithin(String(unitPath.dropFirst(2)), protected), "\(unitPath)")
                #expect(!ExclusionPolicy.isWithin(protected, String(unitPath.dropFirst(2))), "\(unitPath)")
            }
        }
    }

    @Test func derivedDataWorkspaceStatus() throws {
        let home = try makeHome()
        defer { home.remove() }
        let plan = Scanner(home: home.url, configuredLocations: [], installedApps: []).plan()

        func workspace(_ name: String) -> DerivedDataProject.Workspace? {
            for unit in plan.units {
                if case let .derivedDataProject(project) = unit.kind, project.name == name { return project.workspace }
            }
            return nil
        }
        #expect(workspace("Gone") == .missing(home.path("Developer/Gone/Gone.xcodeproj")))
        // Documents の中は確かめない（許可ダイアログが出るため）
        #expect(workspace("App") == .unverifiable(home.path("Documents/App/App.xcodeproj")))
        #expect(workspace("Pods") == .unverifiable(nil))
    }

    @Test func configuredLocationsAreCheckedLikeCatalogPaths() throws {
        let home = try makeHome()
        defer { home.remove() }
        try home.directory(".go/pkg/mod/cache/download")
        try home.file("work/app/package.json")
        try home.directory("work/app/.store/v10")
        try home.directory("Pictures/cache")

        let configFile = home.path("config")
        let configured = [
            ConfiguredLocation(entryID: "go", url: home.path(".go/pkg/mod"), configFile: configFile, markers: ["cache"]),
            ConfiguredLocation(entryID: "pnpm", url: home.path("work/app/.store"), configFile: configFile, markers: ["v10"]),
            ConfiguredLocation(entryID: "npm", url: home.path("Pictures/cache"), configFile: configFile, markers: ["content-v2"]),
            ConfiguredLocation(entryID: "bun", url: home.path("missing"), configFile: configFile, markers: []),
            // 既定の場所と同じなら重ねない
            ConfiguredLocation(entryID: "npm", url: home.path(".npm/_cacache"), configFile: configFile, markers: []),
        ]
        let plan = Scanner(home: home.url, configuredLocations: configured, installedApps: []).plan()

        let go = try #require(plan.units.first { $0.entryID == "go" })
        #expect(go.configFile == configFile)
        #expect(plan.units.filter { $0.entryID == "npm" }.count == 1)
        #expect(plan.units.first { $0.entryID == "npm" }?.configFile == nil)
        #expect(Set(plan.skipped.map(\.reason)) == [.insideProject("~/work/app"), .markerMissing, .notFound])
    }

    @Test func disabledEntriesAreNotScanned() throws {
        let home = try makeHome()
        defer { home.remove() }
        var settings = ScanSettings()
        settings.disabledEntries = ["npm", "derived-data"]
        let plan = Scanner(home: home.url, settings: settings, configuredLocations: [], installedApps: []).plan()

        #expect(!plan.units.contains { $0.entryID == "npm" || $0.entryID == "derived-data" })
        #expect(plan.units.contains { $0.entryID == "gradle" })
    }

    @Test func combinedEntriesBecomeOneUnitWithStableID() throws {
        let home = try TestHome()
        defer { home.remove() }
        let slack = "Library/Application Support/Slack"
        try home.file("\(slack)/Cache/Cache_Data/a", bytes: 4096)
        try home.file("\(slack)/Local Storage/leveldb/b", bytes: 4096)

        let before = try #require(Scanner(home: home.url, configuredLocations: [], installedApps: []).plan().units.first { $0.entryID == "slack" })
        #expect(before.kind == .whole)
        #expect(paths(ScanPlan(units: [before]), home) == ["~/\(slack)/Cache"])

        // 場所が増えても ID は変わらない（「残す」とサイズのキャッシュの鍵）
        try home.file("\(slack)/GPUCache/c", bytes: 4096)
        try home.file("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update.x/d", bytes: 4096)
        let after = try #require(Scanner(home: home.url, configuredLocations: [], installedApps: []).plan().units.first { $0.entryID == "slack" })
        #expect(after.id == before.id)
        #expect(paths(ScanPlan(units: [after]), home) == [
            "~/\(slack)/Cache", "~/\(slack)/GPUCache", "~/Library/Caches/com.tinyspeck.slackmacgap.ShipIt",
        ])
    }

    @Test func logsArePerFolder() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file("Library/Logs/Homebrew/x.log")
        try home.file("Library/Logs/DiagnosticReports/a.ips")
        try home.file("Library/Logs/fsck_hfs.log")

        let plan = Scanner(home: home.url, configuredLocations: [], installedApps: []).plan()
        #expect(paths(plan, home).sorted() == ["~/Library/Logs/DiagnosticReports", "~/Library/Logs/Homebrew"])
    }

    @Test func measureAddsUpAllPaths() throws {
        let home = try makeHome()
        defer { home.remove() }
        let plan = Scanner(home: home.url, configuredLocations: [], installedApps: []).plan()
        let shared = try #require(plan.units.first { $0.kind == .sharedXcodeCache })

        let stats = Scanner.measure(shared)
        #expect(stats.files == 2)
        #expect(stats.reclaimableBytes == shared.paths.map { BulkEnumerator.scan($0).reclaimableBytes }.reduce(0, +))
    }
}
