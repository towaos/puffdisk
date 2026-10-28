import Foundation
import Testing
@testable import PuffdiskCore

struct RuleEngineTests {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = ScanSettings()
    let mb: Int64 = 1_000_000

    func stats(_ bytes: Int64, daysAgo: Double? = 100, errors: Int = 0) -> TreeStats {
        var stats = TreeStats()
        stats.files = 1
        stats.reclaimableBytes = bytes
        stats.allocatedBytes = bytes
        stats.latestModification = daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        stats.errors = errors
        return stats
    }

    func unit(_ entryID: String, _ path: String, _ kind: ScanUnit.Kind, configFile: URL? = nil) -> ScanUnit {
        ScanUnit(entryID: entryID, paths: [home.appending(path: path)], kind: kind, configFile: configFile)
    }

    func candidate(_ unit: ScanUnit, _ stats: TreeStats) -> Candidate? {
        RuleEngine.candidate(for: unit, stats: stats, settings: settings, home: home, now: now)
    }

    func project(_ workspace: DerivedDataProject.Workspace, builtDaysAgo: Double?) -> ScanUnit.Kind {
        .derivedDataProject(DerivedDataProject(
            name: "App", workspace: workspace, lastBuild: builtDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }))
    }

    @Test func wholeUnitNeeds100MB() throws {
        let npm = unit("npm", ".npm/_cacache", .whole)
        #expect(candidate(npm, stats(100 * mb - 1)) == nil)

        // 「全体」の単位は直近の更新でも候補にする（7.5）
        let found = try #require(candidate(npm, stats(100 * mb, daysAgo: 0)))
        #expect(found.title == "npm")
        #expect(found.detail == "~/.npm/_cacache")
        #expect(found.category == .cache)
        #expect(found.defaultSelected)
        #expect(found.reasons == [.refetchable("次回 install 時に必要な分だけ再取得")])
        #expect(found.lastUsed == nil)
    }

    @Test func emptyUnitsAreNotCandidates() {
        #expect(candidate(unit("derived-data", "x", .sharedXcodeCache), stats(0)) == nil)
    }

    @Test func mavenIsReviewAndUnchecked() throws {
        let found = try #require(candidate(unit("maven", ".m2/repository", .whole), stats(200 * mb)))
        #expect(found.category == .review)
        #expect(!found.defaultSelected)
    }

    @Test func huggingFaceModelsNeed1GBAndGetReadableTitles() throws {
        let model = unit("huggingface", ".cache/huggingface/hub/models--openai--clip-vit", .child)
        #expect(candidate(model, stats(999 * mb)) == nil)
        let found = try #require(candidate(model, stats(1_000 * mb)))
        #expect(found.title == "openai/clip-vit")
        #expect(!found.defaultSelected)
        #expect(found.lastUsed?.kind == .modified)
    }

    @Test func recentlyUpdatedChildrenAreSkipped() {
        let model = unit("huggingface", ".cache/huggingface/hub/models--a--b", .child)
        #expect(candidate(model, stats(5_000 * mb, daysAgo: 6)) == nil)
        #expect(candidate(model, stats(5_000 * mb, daysAgo: 7)) != nil)
    }

    @Test func staleToolDataNeeds90Days() throws {
        let jetbrains = unit("jetbrains", "Library/Caches/JetBrains/IntelliJIdea2024.1", .child)
        #expect(candidate(jetbrains, stats(500 * mb, daysAgo: 89)) == nil)
        let found = try #require(candidate(jetbrains, stats(500 * mb, daysAgo: 120)))
        #expect(found.reasons.first == .notUpdated(days: 120))
        #expect(found.title == "IntelliJIdea2024.1")
    }

    @Test func derivedDataMissingWorkspaceIgnoresBuildAge() throws {
        let workspace = URL(filePath: "/Users/someone/Developer/Gone/Gone.xcodeproj")
        let found = try #require(candidate(
            unit("derived-data", "Library/Developer/Xcode/DerivedData/App-x", project(.missing(workspace), builtDaysAgo: 8)),
            stats(50 * mb, daysAgo: 8)))
        #expect(found.reasons.first == .workspaceMissing)
        #expect(found.detail == "~/Developer/Gone/Gone.xcodeproj")
        #expect(found.lastUsed?.kind == .built)

        // 直近に更新されたものは、元プロジェクトがなくても候補にしない
        #expect(candidate(
            unit("derived-data", "Library/Developer/Xcode/DerivedData/App-x", project(.missing(workspace), builtDaysAgo: 1)),
            stats(50 * mb, daysAgo: 1)) == nil)
    }

    @Test func derivedDataExistingWorkspaceNeeds30DaysWithoutBuild() throws {
        let workspace = URL(filePath: "/Users/someone/Developer/App/App.xcodeproj")
        let path = "Library/Developer/Xcode/DerivedData/App-x"
        #expect(candidate(unit("derived-data", path, project(.exists(workspace), builtDaysAgo: 29)), stats(50 * mb)) == nil)

        let found = try #require(candidate(unit("derived-data", path, project(.exists(workspace), builtDaysAgo: 45)), stats(50 * mb)))
        #expect(found.reasons == [.notBuilt(days: 45)])
    }

    @Test func derivedDataUnverifiableIsNeverReportedAsMissing() throws {
        let workspace = URL(filePath: "/Users/someone/Documents/App/App.xcodeproj")
        let path = "Library/Developer/Xcode/DerivedData/App-x"
        #expect(candidate(unit("derived-data", path, project(.unverifiable(workspace), builtDaysAgo: 10)), stats(50 * mb)) == nil)

        let found = try #require(candidate(unit("derived-data", path, project(.unverifiable(workspace), builtDaysAgo: 40)), stats(50 * mb)))
        #expect(found.reasons == [.notBuilt(days: 40), .workspaceUnverifiable])
        #expect(!found.reasons.contains(.workspaceMissing))

        // info.plist がないときは、フォルダの中身の更新日で判定する
        let noPlist = try #require(candidate(unit("derived-data", path, project(.unverifiable(nil), builtDaysAgo: nil)), stats(50 * mb, daysAgo: 60)))
        #expect(noPlist.detail == "~/Library/Developer/Xcode/DerivedData/App-x")
        #expect(noPlist.lastUsed?.kind == .modified)
    }

    @Test func derivedDataTinyFoldersAreSkipped() {
        let path = "Library/Developer/Xcode/DerivedData/App-x"
        #expect(candidate(unit("derived-data", path, project(.unverifiable(nil), builtDaysAgo: 100)), stats(20_000)) == nil)
    }

    @Test func sharedXcodeCacheNeeds100MB() throws {
        let shared = ScanUnit(entryID: "derived-data", paths: [
            home.appending(path: "Library/Developer/Xcode/DerivedData/ModuleCache.noindex"),
            home.appending(path: "Library/Developer/Xcode/DerivedData/SymbolCache.noindex"),
        ], kind: .sharedXcodeCache, configFile: nil)
        #expect(candidate(shared, stats(99 * mb, daysAgo: 0)) == nil)
        let found = try #require(candidate(shared, stats(150 * mb, daysAgo: 0)))
        #expect(found.title == "Xcode 共有キャッシュ")
        #expect(found.detail == "~/Library/Developer/Xcode/DerivedData")
        #expect(found.paths.count == 2)
    }

    @Test func notesConfigFileAndUnreadableFiles() throws {
        let go = unit("go", ".go/pkg/mod", .whole, configFile: home.appending(path: "Library/Application Support/go/env"))
        let found = try #require(candidate(go, stats(4_000 * mb, errors: 3)))
        #expect(found.reasons == [
            .refetchable("次回ビルド時に再取得"),
            .configured("~/Library/Application Support/go/env"),
            .partiallyUnreadable,
        ])
    }
}
