import Foundation
import OSLog
import PuffdiskCore
import SwiftData

/// 測る単位ごとのサイズのキャッシュ（DESIGN.md 9.3・10.2）。
/// M1 では起動直後に前回の結果を出すためだけに使い、測り直しは毎回行う。FSEvents による差分スキャンは M5
@Model
final class SizeCacheRecord {
    /// `ScanUnit.id`（パス。複数の場所をまとめた単位は改行でつなぐ）
    @Attribute(.unique) var path: String
    var reclaimableBytes: Int64
    var allocatedBytes: Int64
    var fileCount: Int
    var latestModification: Date?
    var errors: Int
    var measuredAt: Date
    var needsRecount: Bool

    init(path: String, stats: TreeStats, measuredAt: Date) {
        self.path = path
        reclaimableBytes = stats.reclaimableBytes
        allocatedBytes = stats.allocatedBytes
        fileCount = stats.files
        latestModification = stats.latestModification
        errors = stats.errors
        self.measuredAt = measuredAt
        needsRecount = false
    }

    func update(stats: TreeStats, measuredAt: Date) {
        reclaimableBytes = stats.reclaimableBytes
        allocatedBytes = stats.allocatedBytes
        fileCount = stats.files
        latestModification = stats.latestModification
        errors = stats.errors
        self.measuredAt = measuredAt
        needsRecount = false
    }

    var stats: TreeStats {
        var stats = TreeStats()
        stats.files = fileCount
        stats.reclaimableBytes = reclaimableBytes
        stats.allocatedBytes = allocatedBytes
        stats.latestModification = latestModification
        stats.errors = errors
        return stats
    }
}

@MainActor
final class SizeCacheStore {
    private static let logger = Logger(subsystem: "com.towaos.puffdisk", category: "SizeCache")
    /// コンテキストはコンテナを保持しないので、ここで持っておく
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// `~/Library/Application Support/Puffdisk/Puffdisk.store`（DESIGN.md D15）。開けなければメモリ上だけで動かす
    init() {
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "Puffdisk", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            container = try ModelContainer(for: SizeCacheRecord.self,
                                           configurations: ModelConfiguration(url: folder.appending(path: "Puffdisk.store")))
        } catch {
            Self.logger.error("サイズのキャッシュを開けない: \(error.localizedDescription, privacy: .public)")
            container = try! ModelContainer(for: SizeCacheRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    func records(for ids: [String]) -> [String: SizeCacheRecord] {
        let records = (try? context.fetch(FetchDescriptor<SizeCacheRecord>(predicate: #Predicate { ids.contains($0.path) }))) ?? []
        return Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func store(_ stats: TreeStats, for id: String, at date: Date) {
        if let record = records(for: [id])[id] {
            record.update(stats: stats, measuredAt: date)
        } else {
            context.insert(SizeCacheRecord(path: id, stats: stats, measuredAt: date))
        }
    }

    /// 今回の単位にないものを消して保存する
    func finish(keeping ids: Set<String>) {
        do {
            let all = try context.fetch(FetchDescriptor<SizeCacheRecord>())
            for record in all where !ids.contains(record.path) {
                context.delete(record)
            }
            try context.save()
        } catch {
            Self.logger.error("サイズのキャッシュを保存できない: \(error.localizedDescription, privacy: .public)")
        }
    }
}
