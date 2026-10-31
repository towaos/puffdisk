import Foundation
import Testing
@testable import PuffdiskCore

struct ExclusionPolicyTests {
    @Test func allowsCatalogLocation() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(".npm/_cacache/content-v2")

        #expect(ExclusionPolicy(home: home.url).check(location: home.path(".npm/_cacache")) == nil)
    }

    @Test func rejectsMissingAndOutsideHome() throws {
        let home = try TestHome()
        defer { home.remove() }
        let policy = ExclusionPolicy(home: home.url)

        #expect(policy.check(location: home.path(".npm/_cacache")) == .notFound)
        #expect(policy.check(location: URL(filePath: "/tmp")) == .outsideHome)
        #expect(policy.check(location: home.url.deletingLastPathComponent()) == .outsideHome)
    }

    @Test(arguments: [
        ("", "~"),
        ("Documents", "~/Documents"),
        ("Library", "~/Library"),
        (".cache", "~/.cache/uv"),
        ("Library/Developer/Xcode", "~/Library/Developer/Xcode/Archives"),
        (".cargo", "~/.cargo/bin"),
    ])
    func rejectsLocationsContainingImportantFolders(location: String, contained: String) throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(location)

        let result = ExclusionPolicy(home: home.url).check(location: home.path(location))
        #expect(result == .containsImportantFolder(contained))
    }

    @Test(arguments: [".cargo/bin/tool-cache", "Library/Application Support/Puffdisk/Purge.noindex",
                      "Library/Developer/CoreSimulator/Devices/x", "Library/CloudStorage/Dropbox/cache"])
    func rejectsProtectedLocations(location: String) throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(location)

        guard case .protectedLocation = ExclusionPolicy(home: home.url).check(location: home.path(location)) else {
            Issue.record("\(location) が拒否されない")
            return
        }
    }

    @Test func rejectsPrivacyProtectedFoldersWithoutReading() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory("Documents/npm-cache")
        let policy = ExclusionPolicy(home: home.url)

        #expect(policy.check(location: home.path("Documents/npm-cache")) == .privacyProtected)
        #expect(policy.isPrivacyProtected(home.path("Desktop/App/App.xcodeproj")))
        #expect(policy.isPrivacyProtected(URL(filePath: "/Volumes/External/App.xcodeproj")))
        #expect(!policy.isPrivacyProtected(home.path("Developer/App/App.xcodeproj")))
    }

    @Test func rejectsSymbolicLinkInPath() throws {
        let home = try TestHome()
        defer { home.remove() }
        let real = try home.directory("elsewhere/_cacache")
        try FileManager.default.createSymbolicLink(at: home.path(".npm"), withDestinationURL: real.deletingLastPathComponent())

        #expect(ExclusionPolicy(home: home.url).check(location: home.path(".npm/_cacache")) == .symbolicLinkInPath("~/.npm"))
    }

    @Test(arguments: ["package.json", ".git", "App.xcodeproj", "go.mod"])
    func rejectsLocationsInsideProjects(marker: String) throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory("work/app/.cache/tool")
        if marker.hasSuffix(".xcodeproj") {
            try home.directory("work/app/\(marker)")
        } else {
            // `.git` はファイルの場合もある（worktree・submodule）
            try home.file("work/app/\(marker)")
        }

        #expect(ExclusionPolicy(home: home.url).check(location: home.path("work/app/.cache/tool")) == .insideProject("~/work/app"))
    }

    @Test func ignoresDotfilesRepositoryAtHome() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory(".git")
        try home.file("package.json")
        try home.directory(".npm/_cacache")

        #expect(ExclusionPolicy(home: home.url).check(location: home.path(".npm/_cacache")) == nil)
    }

    @Test func rejectsSyncedFolders() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.file("Sync/.stfolder")
        try home.directory("Sync/cache")

        #expect(ExclusionPolicy(home: home.url).check(location: home.path("Sync/cache")) == .cloudSynced)
    }

    @Test func checksMarkersForConfiguredLocations() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.directory("pnpm-store/v10")
        try home.directory("not-a-store/photos")
        let policy = ExclusionPolicy(home: home.url)

        #expect(policy.check(location: home.path("pnpm-store"), markers: ["v3", "v10"]) == nil)
        #expect(policy.check(location: home.path("not-a-store"), markers: ["v3", "v10"]) == .markerMissing)
    }

    @Test func rejectsUnreadableLocations() throws {
        let home = try TestHome()
        defer { home.remove() }
        let cache = try home.directory("Library/Application Support/App/Cache")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cache.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path(percentEncoded: false)) }

        #expect(ExclusionPolicy(home: home.url).check(location: cache) == .unreadable)
    }
}
