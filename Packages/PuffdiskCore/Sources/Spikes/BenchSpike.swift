import Foundation
import PuffdiskCore

/// S5: getattrlistbulk と FileManager の列挙の速さ
enum BenchSpike {
    static func run(paths: [String]) {
        guard !paths.isEmpty else {
            print("フォルダを1つ以上指定してください")
            exit(64)
        }
        for path in paths {
            let url = expandTilde(path)
            print("== \(url.path(percentEncoded: false))")
            // 1回目はディスクキャッシュを温めるため捨てる
            _ = BulkEnumerator.scan(url)
            for round in 1...3 {
                let (fileManagerStats, fileManagerTime) = measure { fileManagerScan(url) }
                let (bulkStats, bulkTime) = measure { BulkEnumerator.scan(url) }
                print("  \(round)回目  FileManager \(fileManagerTime.milliseconds)（\(fileManagerStats.files) ファイル、\(formatBytes(fileManagerStats.reclaimableBytes))）"
                      + "  getattrlistbulk \(bulkTime.milliseconds)（\(bulkStats.files) ファイル、\(formatBytes(bulkStats.reclaimableBytes))）")
            }
        }
    }

    /// BulkEnumerator と同じ集計を FileManager で行う
    static func fileManagerScan(_ root: URL) -> TreeStats {
        var stats = TreeStats()
        var links: [UInt64: (links: Int, seen: Int, bytes: Int64)] = [:]
        var singleLinkBytes: Int64 = 0
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
            .linkCountKey, .contentModificationDateKey, .fileIdentifierKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in stats.errors += 1; return true }
        ) else {
            stats.errors += 1
            return stats
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                stats.errors += 1
                continue
            }
            if let date = values.contentModificationDate, stats.latestModification.map({ date > $0 }) ?? true {
                stats.latestModification = date
            }
            if values.isSymbolicLink == true {
                stats.symlinks += 1
            } else if values.isDirectory == true {
                stats.directories += 1
            } else if values.isRegularFile == true {
                stats.files += 1
                let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                let linkCount = values.linkCount ?? 1
                if linkCount <= 1 {
                    stats.allocatedBytes += bytes
                    singleLinkBytes += bytes
                } else if let id = values.fileIdentifier {
                    if var entry = links[id] {
                        entry.seen += 1
                        links[id] = entry
                    } else {
                        links[id] = (linkCount, 1, bytes)
                        stats.allocatedBytes += bytes
                    }
                }
            } else {
                stats.others += 1
            }
        }
        stats.reclaimableBytes = singleLinkBytes + links.values.reduce(0) { $0 + ($1.seen >= $1.links ? $1.bytes : 0) }
        return stats
    }
}
