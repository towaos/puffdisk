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

    @Test(arguments: CacheCatalog.protectedPaths)
    func protectedPathsAreNotCovered(protected: String) {
        // 触らないものが、カタログの場所と同じか、その中か、それを含む場所になっていないこと
        let protectedComponents = protected.split(separator: "/").map(String.init)
        for path in CacheCatalog.entries.flatMap(\.paths) {
            let components = path.split(separator: "/").map(String.init)
            #expect(!Self.isWithin(protectedComponents, components), "\(protected) は \(path) の中にある")
            #expect(!Self.isWithin(components, protectedComponents), "\(path) は \(protected) の中にある")
        }
    }

    /// `path` が `base`（`*` を含みうる）と同じか、その中にあるか
    static func isWithin(_ path: [String], _ base: [String]) -> Bool {
        guard path.count >= base.count else { return false }
        return zip(path, base).allSatisfy { name, pattern in
            guard pattern.contains("*") else { return name == pattern }
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
            return name.hasPrefix(String(parts[0])) && name.hasSuffix(String(parts.last!))
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
