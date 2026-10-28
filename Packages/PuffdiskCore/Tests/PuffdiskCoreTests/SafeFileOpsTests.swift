import Darwin
import Foundation
import Testing
@testable import PuffdiskCore

struct SafeFileOpsTests {
    let fileManager = FileManager.default

    func ops(_ home: TestHome, configured: [ConfiguredLocation] = []) -> SafeFileOps {
        SafeFileOps(home: home.url, configuredLocations: configured)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    // MARK: - 移動できるもの

    @Test func movesWholeLocationIntoPurge() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file(".npm/_cacache/content-v2/a", bytes: 4096)
        let id = UUID()

        let moved = try ops(home).moveToPurge(home.path(".npm/_cacache"), id: id)

        #expect(!exists(home.path(".npm/_cacache")))
        #expect(exists(home.path(".npm")))
        #expect(moved == home.path("Library/Application Support/Puffdisk/Purge.noindex/\(id.uuidString)/_cacache"))
        #expect(exists(moved.appending(path: "content-v2/a")))

        // アプリ専用のフォルダは 0700（DESIGN.md 11.4）
        for folder in ["Library/Application Support/Puffdisk", "Library/Application Support/Puffdisk/Purge.noindex"] {
            let mode = try #require(try fileManager.attributesOfItem(atPath: home.path(folder).path(percentEncoded: false))[.posixPermissions] as? Int)
            #expect(mode == 0o700, "\(folder)")
        }
    }

    @Test func movesDirectChildOfPerChildLocation() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file(".cache/huggingface/hub/models--a--b/blob", bytes: 4096)

        try ops(home).moveToPurge(home.path(".cache/huggingface/hub/models--a--b"), id: UUID())
        #expect(!exists(home.path(".cache/huggingface/hub/models--a--b")))
        #expect(exists(home.path(".cache/huggingface/hub")))
    }

    @Test func movesConfiguredLocation() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(".go/pkg/mod/cache/download")
        let configured = [ConfiguredLocation(entryID: "go", url: home.path(".go/pkg/mod"), configFile: home.path("env"), markers: ["cache"])]

        try ops(home, configured: configured).moveToPurge(home.path(".go/pkg/mod"), id: UUID())
        #expect(!exists(home.path(".go/pkg/mod")))
    }

    // MARK: - 拒否するもの（DESIGN.md 14: カタログ外・プロジェクト内に触れない）

    @Test(arguments: [
        "Documents/report.pdf",
        ".npm",                                   // カタログの場所の親
        ".npm/_cacache/content-v2/sha512",        // カタログの場所の2階層下（「全体」の単位の中）
        ".cache/huggingface",
        ".cargo/bin",
        ".cargo/config.toml",
        ".gradle/gradle.properties",
        "Library/Developer/Xcode/Archives",
        "Library/Developer/CoreSimulator/Devices",
        "Library/Caches/com.apple.Safari",
        "Library/Application Support/Puffdisk",
    ])
    func rejectsPathsOutsideCatalog(path: String) throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file("\(path)/x")
        try home.file(".npm/_cacache/content-v2/sha512/x")
        try home.directory(".cache/huggingface/hub")
        try home.directory(".cargo/registry/cache")
        try home.directory(".gradle/caches")
        try home.directory("Library/Developer/Xcode/DerivedData")
        try home.directory("Library/Developer/CoreSimulator/Caches")

        #expect(throws: SafeFileOps.Failure.notAllowed) {
            try ops(home).moveToPurge(home.path(path), id: UUID())
        }
        #expect(exists(home.path(path)))
    }

    @Test func rejectsHomeAndOutsideHome() throws {
        let home = try TestHome()
        defer { home.remove() }
        #expect(throws: SafeFileOps.Failure.notAllowed) { try ops(home).moveToPurge(home.url, id: UUID()) }
        #expect(throws: SafeFileOps.Failure.notAllowed) { try ops(home).moveToPurge(URL(filePath: "/tmp"), id: UUID()) }
    }

    @Test(arguments: [".npm/../.npm/_cacache", ".npm/./_cacache", ".npm//_cacache"])
    func rejectsUnnormalizedPaths(path: String) throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(".npm/_cacache")

        let url = URL(filePath: home.url.path(percentEncoded: false) + path)
        #expect(throws: SafeFileOps.Failure.invalidPath) { try ops(home).moveToPurge(url, id: UUID()) }
        #expect(exists(home.path(".npm/_cacache")))
    }

    @Test func rejectsConfiguredLocationInsideProject() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file("work/app/package.json")
        try home.directory("work/app/store/v10")
        let configured = [ConfiguredLocation(entryID: "pnpm", url: home.path("work/app/store"), configFile: home.path("rc"), markers: ["v10"])]

        #expect(throws: SafeFileOps.Failure.notAllowed) {
            try ops(home, configured: configured).moveToPurge(home.path("work/app/store"), id: UUID())
        }
        #expect(exists(home.path("work/app/store/v10")))
    }

    @Test func rejectsSymbolicLinkInPath() throws {
        let home = try TestHome()
        defer { home.remove() }
        // ~/.npm が別の場所（ここではプロジェクト）を指している
        try home.file("work/app/package.json")
        try home.directory("work/app/_cacache")
        try fileManager.createSymbolicLink(at: home.path(".npm"), withDestinationURL: home.path("work/app"))

        #expect(throws: SafeFileOps.Failure.notAllowed) {
            try ops(home).moveToPurge(home.path(".npm/_cacache"), id: UUID())
        }
        #expect(exists(home.path("work/app/_cacache")))
    }

    @Test func refusesWhenPathIsSwappedForSymbolicLinkAfterCheck() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(".npm/_cacache")
        try home.directory("work/app/_cacache")
        let ops = ops(home)

        // 確認のあとでパスの途中を差し替えられた場合。ファイルディスクリプタで開くときに止まる
        try fileManager.removeItem(at: home.path(".npm"))
        try fileManager.createSymbolicLink(at: home.path(".npm"), withDestinationURL: home.path("work/app"))
        #expect(throws: SafeFileOps.Failure.symbolicLinkInPath(".npm")) {
            _ = try ops.openDirectory([".npm"])
        }
        #expect(exists(home.path("work/app/_cacache")))
    }

    // MARK: - 削除

    @Test func emptyPurgeRemovesReadOnlyTreesWithoutFollowingLinks() throws {
        let home = try TestHome()
        defer { home.remove() }
        // 外にある大事なファイルへのシンボリックリンクを含むキャッシュ
        let important = try home.file("Documents/important.txt")
        try home.file(".go/pkg/mod/cache/download/x")
        try home.file(".go/pkg/mod/github.com/a/b@v1/go.mod")
        try fileManager.createSymbolicLink(at: home.path(".go/pkg/mod/github.com/a/b@v1/link"), withDestinationURL: important)
        try fileManager.createSymbolicLink(at: home.path(".go/pkg/mod/github.com/a/dirlink"), withDestinationURL: home.path("Documents"))
        // Go のモジュールキャッシュは読み取り専用（S10）
        for path in [".go/pkg/mod/github.com/a/b@v1/go.mod"] {
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.path(path).path(percentEncoded: false))
        }
        for path in [".go/pkg/mod/github.com/a/b@v1", ".go/pkg/mod/github.com/a"] {
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path(path).path(percentEncoded: false))
        }
        let configured = [ConfiguredLocation(entryID: "go", url: home.path(".go/pkg/mod"), configFile: home.path("env"), markers: ["cache"])]
        let ops = ops(home, configured: configured)

        try ops.moveToPurge(home.path(".go/pkg/mod"), id: UUID())
        #expect(ops.emptyPurge() == 0)

        #expect(try fileManager.contentsOfDirectory(atPath: ops.purgeDirectory.path(percentEncoded: false)).isEmpty)
        #expect(exists(important))
        #expect(exists(home.path("Documents")))
    }

    @Test func emptyPurgeWithoutPurgeFolderDoesNothing() throws {
        let home = try TestHome()
        defer { home.remove() }
        #expect(ops(home).emptyPurge() == 0)
    }
}
