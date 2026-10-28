import Foundation
import Testing
@testable import PuffdiskCore

struct PurgerTests {
    static let hash = String(repeating: "q", count: 28)
    let fileManager = FileManager.default

    /// 「全体」の単位は削除の直前に測り直さないので、大きなファイルを作らずにサイズだけ大きくする
    func candidates(_ home: TestHome, now: Date = Date()) -> [Candidate] {
        let scanner = Scanner(home: home.url, configuredLocations: [])
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
        try home.file(".m2/repository/org/x.jar", bytes: 4096)
        return home
    }

    @Test func movesCacheCandidatesAndEmptiesPurge() throws {
        let home = try makeHome()
        defer { home.remove() }
        let found = candidates(home).filter { $0.category == .cache }
        #expect(found.count == 2)

        let purger = Purger(home: home.url, configuredLocations: [])
        let result = purger.moveToPurge(found, kept: [])
        #expect(result.moved.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(!fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))

        #expect(purger.emptyPurge() == 0)
        let purge = SafeFileOps(home: home.url).purgeDirectory.path(percentEncoded: false)
        #expect(try fileManager.contentsOfDirectory(atPath: purge).isEmpty)
    }

    @Test func doesNotDeleteReviewOrKeptCandidates() throws {
        let home = try makeHome()
        defer { home.remove() }
        let all = candidates(home)
        let npm = try #require(all.first { $0.entryID == "npm" })
        let maven = try #require(all.first { $0.entryID == "maven" })

        let result = Purger(home: home.url, configuredLocations: []).moveToPurge([npm, maven], kept: [npm.id])
        #expect(result.moved.isEmpty)
        #expect(result.skipped.map(\.reason) == [.kept, .notCache])
        #expect(fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))
        #expect(fileManager.fileExists(atPath: home.path(".m2/repository").path(percentEncoded: false)))
    }

    @Test func rechecksConditionsBeforeMoving() throws {
        let home = try makeHome()
        defer { home.remove() }
        let derivedData = try #require(candidates(home).first { $0.entryID == "derived-data" })

        // スキャンのあとにビルドされた
        try home.file("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)/Build/new", bytes: 4096)
        let result = Purger(home: home.url, configuredLocations: []).moveToPurge([derivedData], kept: [])
        #expect(result.skipped.map(\.reason) == [.changed])
        #expect(fileManager.fileExists(atPath: home.path("Library/Developer/Xcode/DerivedData/Old-\(Self.hash)").path(percentEncoded: false)))
    }

    @Test func skipsCandidatesThatBecameProjects() throws {
        let home = try makeHome()
        defer { home.remove() }
        let npm = try #require(candidates(home).first { $0.entryID == "npm" })

        // スキャンのあとに、キャッシュの場所がプロジェクトの中だと分かった
        try home.file(".npm/package.json")
        let result = Purger(home: home.url, configuredLocations: []).moveToPurge([npm], kept: [])
        #expect(result.skipped.map(\.reason) == [.changed])
        #expect(fileManager.fileExists(atPath: home.path(".npm/_cacache").path(percentEncoded: false)))
    }

    @Test func recoversPurgeLeftByCrash() throws {
        let home = try makeHome()
        defer { home.remove() }
        // 移動のあと、削除の途中で強制終了した状態
        let ops = SafeFileOps(home: home.url, configuredLocations: [])
        try ops.moveToPurge(home.path(".npm/_cacache"), id: UUID())
        let half = ops.purgeDirectory.appending(path: UUID().uuidString)
        try fileManager.createDirectory(at: half.appending(path: "partial/deep"), withIntermediateDirectories: true)

        #expect(Purger(home: home.url, configuredLocations: []).emptyPurge() == 0)
        #expect(try fileManager.contentsOfDirectory(atPath: ops.purgeDirectory.path(percentEncoded: false)).isEmpty)
    }
}
