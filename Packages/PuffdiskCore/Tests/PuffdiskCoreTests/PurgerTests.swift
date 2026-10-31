import Foundation
import Testing
@testable import PuffdiskCore

struct PurgerTests {
    static let hash = String(repeating: "q", count: 28)
    let fileManager = FileManager.default

    /// 「全体」の単位は削除の直前に測り直さないので、大きなファイルを作らずにサイズだけ大きくする
    func candidates(_ home: TestHome, now: Date = Date()) -> [Candidate] {
        let scanner = Scanner(home: home.url, configuredLocations: [], installedApps: [])
        return scanner.plan().units.compactMap { unit in
            var stats = Scanner.measure(unit)
            if unit.kind == .whole { stats.reclaimableBytes = 500_000_000 }
            return RuleEngine.candidate(for: unit, stats: stats, settings: scanner.settings, home: home.url, now: now)
        }
    }

    func makeHome() throws -> TestHome {
        let home = try TestHome()
        try home.file(".npm/_cacache/content-v2/a", bytes: 4096)
        try home.file("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)/Build/x", bytes: 2_000_000)
        try home.setModified("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)/Build/x", daysAgo: 60)
        try home.setModified("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)/Build", daysAgo: 60)
        try home.setModified("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)", daysAgo: 60)
        return home
    }

    @Test func movesCacheCandidatesAndEmptiesPurge() throws {
        let home = try makeHome()
        defer { home.remove() }
        let found = candidates(home)
        #expect(found.count == 2)

        let purger = Purger(home: home.url, configuredLocations: [], installedApps: [])
        let result = purger.moveToPurge(found, kept: [])
        #expect(result.moved.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(!fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))

        #expect(purger.emptyPurge() == 0)
        let purge = SafeFileOps(home: home.url).purgeDirectory.path(percentEncoded: false)
        #expect(try fileManager.contentsOfDirectory(atPath: purge).isEmpty)
    }

    @Test func doesNotDeleteKeptCandidates() throws {
        let home = try makeHome()
        defer { home.remove() }
        let npm = try #require(candidates(home).first { $0.entryID == "npm" })

        let result = Purger(home: home.url, configuredLocations: [], installedApps: []).moveToPurge([npm], kept: [npm.id])
        #expect(result.moved.isEmpty)
        #expect(result.skipped.map(\.reason) == [.kept])
        #expect(fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))
    }

    @Test func skipsCandidatesOfRunningApps() throws {
        let home = try makeHome()
        defer { home.remove() }
        try home.file("Library/Application Support/Slack/Cache/a", bytes: 4096)
        let slack = try #require(candidates(home).first { $0.entryID == "slack" })

        let purger = Purger(home: home.url, configuredLocations: [], installedApps: [])
        let running = purger.moveToPurge([slack], kept: [], runningApps: ["com.tinyspeck.slackmacgap"])
        #expect(running.skipped.map(\.reason) == [.appRunning])
        #expect(fileManager.fileExists(atPath: home.path("Library/Application Support/Slack/Cache").path(percentEncoded: false)))

        #expect(purger.moveToPurge([slack], kept: [], runningApps: ["com.apple.Safari"]).moved.count == 1)
    }

    @Test func movesAllFoldersOfCombinedCandidateButNotAppData() throws {
        let home = try makeHome()
        defer { home.remove() }
        let slack = "Library/Application Support/Slack"
        try home.file("\(slack)/Cache/a", bytes: 4096)
        try home.file("\(slack)/Code Cache/b", bytes: 4096)
        try home.file("\(slack)/Local Storage/leveldb/c", bytes: 4096)
        try home.file("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update.x/d", bytes: 4096)
        let candidate = try #require(candidates(home).first { $0.entryID == "slack" })
        #expect(candidate.paths.count == 3)

        let result = Purger(home: home.url, configuredLocations: [], installedApps: []).moveToPurge([candidate], kept: [])
        #expect(result.moved.count == 1)
        for gone in ["\(slack)/Cache", "\(slack)/Code Cache", "Library/Caches/com.tinyspeck.slackmacgap.ShipIt"] {
            #expect(!fileManager.fileExists(atPath: home.path(gone).path(percentEncoded: false)), "\(gone)")
        }
        #expect(fileManager.fileExists(atPath: home.path("\(slack)/Local Storage/leveldb/c").path(percentEncoded: false)))
    }

    @Test func rechecksConditionsBeforeMoving() throws {
        let home = try makeHome()
        defer { home.remove() }
        let derivedData = try #require(candidates(home).first { $0.entryID == "derived-data" })

        // スキャンのあとにビルドされた
        try home.file("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)/Build/new", bytes: 4096)
        let result = Purger(home: home.url, configuredLocations: [], installedApps: []).moveToPurge([derivedData], kept: [])
        #expect(result.skipped.map(\.reason) == [.changed])
        #expect(fileManager.fileExists(atPath: home.path("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)").path(percentEncoded: false)))
    }

    @Test func skipsCandidatesThatBecameProjects() throws {
        let home = try makeHome()
        defer { home.remove() }
        let npm = try #require(candidates(home).first { $0.entryID == "npm" })

        // スキャンのあとに、キャッシュの場所がプロジェクトの中だと分かった
        try home.file(".npm/package.json")
        let result = Purger(home: home.url, configuredLocations: [], installedApps: []).moveToPurge([npm], kept: [])
        #expect(result.skipped.map(\.reason) == [.changed])
        #expect(fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))
    }

    @Test func recoversPurgeLeftByCrash() throws {
        let home = try makeHome()
        defer { home.remove() }
        // 移動のあと、削除の途中で強制終了した状態
        let ops = SafeFileOps(home: home.url, configuredLocations: [], installedApps: [])
        try ops.moveToPurge(home.path(".npm/_cacache"), id: UUID())
        let half = ops.purgeDirectory.appending(path: UUID().uuidString)
        try fileManager.createDirectory(at: half.appending(path: "partial/deep"), withIntermediateDirectories: true)

        #expect(Purger(home: home.url, configuredLocations: [], installedApps: []).emptyPurge() == 0)
        #expect(try fileManager.contentsOfDirectory(atPath: ops.purgeDirectory.path(percentEncoded: false)).isEmpty)
    }
}
