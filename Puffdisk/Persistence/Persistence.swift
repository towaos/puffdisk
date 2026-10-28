import Foundation
import OSLog
import SwiftData

/// SwiftData の保存先（DESIGN.md 9.1・10.2）
@MainActor
final class Persistence {
    private static let logger = Logger(subsystem: "com.towaos.puffdisk", category: "Persistence")
    /// コンテキストはコンテナを保持しないので、ここで持っておく
    private let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// `~/Library/Application Support/Puffdisk/Puffdisk.store`（DESIGN.md D15）。開けなければメモリ上だけで動かす
    init() {
        let schema = Schema([SizeCacheRecord.self, KeepRule.self])
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "Puffdisk", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, url: folder.appending(path: "Puffdisk.store")))
        } catch {
            Self.logger.error("保存先を開けない: \(error.localizedDescription, privacy: .public)")
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("保存できない: \(error.localizedDescription, privacy: .public)")
        }
    }
}
