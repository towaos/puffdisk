import Foundation
import Testing
@testable import PuffdiskCore

struct CacheCatalogTests {
    @Test func idsAreUnique() {
        let ids = CacheCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func pathsStayInsideHome() {
        for path in CacheCatalog.entries.flatMap(\.paths) {
            #expect(!path.hasPrefix("/"), "\(path)")
            #expect(!path.split(separator: "/").contains(".."), "\(path)")
        }
    }

    @Test func combinedEntriesCanShareOnePurgeFolder() {
        // 「まとめて」の単位は同じ Purge.noindex/<ID>/ に並べるので、最後の要素が重なってはいけない（APFS は大文字・小文字を区別しない）
        for entry in CacheCatalog.entries where entry.unit == .combined {
            let names = entry.paths.map { $0.split(separator: "/").last!.lowercased() }
            #expect(Set(names).count == names.count, "\(entry.id)")
            #expect(!entry.paths.contains { $0.contains("*") }, "\(entry.id)")
        }
    }

    @Test func electronCachesLeaveAppDataAlone() {
        let paths = CacheCatalog.electronCaches("App")
        for data in ["Service Worker", "IndexedDB", "Local Storage", "Session Storage", "Cookies", "Preferences", "User"] {
            #expect(!paths.contains("App/\(data)"), "\(data)")
        }
    }

    @Test(arguments: CacheCatalog.protectedPaths)
    func protectedPathsAreNotCovered(protected: String) {
        // 触らないものが、カタログの場所と同じか、その中か、それを含む場所になっていないこと
        for path in CacheCatalog.entries.flatMap(\.paths) {
            #expect(!ExclusionPolicy.isWithin(protected, path), "\(protected) は \(path) の中にある")
            #expect(!ExclusionPolicy.isWithin(path, protected), "\(path) は \(protected) の中にある")
        }
    }

    @Test func resolvesWildcardAndSkipsMissing() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let xcode = home.appending(path: "Library/Developer/Xcode")
        for name in ["iOS DeviceSupport", "watchOS DeviceSupport", "Archives"] {
            try FileManager.default.createDirectory(at: xcode.appending(path: name), withIntermediateDirectories: true)
        }

        let entry = try #require(CacheCatalog.entries.first { $0.id == "device-support" })
        let names = entry.resolvedLocations(home: home).map(\.lastPathComponent)
        #expect(names == ["iOS DeviceSupport", "watchOS DeviceSupport"])

        let npm = try #require(CacheCatalog.entries.first { $0.id == "npm" })
        #expect(npm.resolvedLocations(home: home).isEmpty)
    }
}
