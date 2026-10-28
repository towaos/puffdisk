import Foundation
import Testing
@testable import PuffdiskCore

struct BulkEnumeratorTests {
    let fileManager = FileManager.default

    func makeTree() throws -> URL {
        let root = fileManager.temporaryDirectory.appending(path: "bulk-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root.appending(path: "candidate/sub"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "outside"), withIntermediateDirectories: true)
        let data = Data(repeating: 0x61, count: 64 * 1024)
        try data.write(to: root.appending(path: "candidate/a.bin"))
        try data.write(to: root.appending(path: "candidate/sub/b.bin"))
        try data.write(to: root.appending(path: "candidate/sub/shared-inside.bin"))
        try data.write(to: root.appending(path: "candidate/shared-outside.bin"))
        try data.write(to: root.appending(path: "outside/big.bin"))
        // 候補の中だけでリンクしているファイルと、候補の外からもリンクされているファイル
        try fileManager.linkItem(at: root.appending(path: "candidate/sub/shared-inside.bin"),
                                 to: root.appending(path: "candidate/shared-inside-link.bin"))
        try fileManager.linkItem(at: root.appending(path: "candidate/shared-outside.bin"),
                                 to: root.appending(path: "outside/shared-outside-link.bin"))
        // シンボリックリンクはたどらない
        try fileManager.createSymbolicLink(at: root.appending(path: "candidate/link-to-outside"),
                                           withDestinationURL: root.appending(path: "outside"))
        return root
    }

    @Test func countsHardLinksOnlyWhenAllLinksAreInside() throws {
        let root = try makeTree()
        defer { try? fileManager.removeItem(at: root) }

        let stats = BulkEnumerator.scan(root.appending(path: "candidate"))
        let unit = try #require(try root.appending(path: "candidate/a.bin").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)

        #expect(stats.files == 5)
        #expect(stats.directories == 1)
        #expect(stats.symlinks == 1)
        #expect(stats.errors == 0)
        // a, b, shared-inside（1回）, shared-outside
        #expect(stats.allocatedBytes == Int64(unit) * 4)
        // shared-outside は外からもリンクされているので空かない
        #expect(stats.reclaimableBytes == Int64(unit) * 3)
        #expect(stats.latestModification != nil)
    }

    @Test func missingRootIsAnError() {
        let stats = BulkEnumerator.scan(URL(filePath: "/nonexistent-\(UUID().uuidString)"))
        #expect(stats.errors == 1)
        #expect(stats.files == 0)
    }
}
