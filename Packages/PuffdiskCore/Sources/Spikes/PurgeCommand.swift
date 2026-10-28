import Foundation
import PuffdiskCore

/// M2: 指定した種類のキャッシュだけを、アプリと同じ手順（再確認 → Purge.noindex → 削除）で消し、空き容量の増え方を見る
enum PurgeCommand {
    static func run(arguments: [String]) {
        guard let entryID = arguments.first, arguments.contains("--yes") else {
            print("使い方: puffdisk-spikes purge <カタログの種類> --yes   （例: puppeteer）")
            exit(64)
        }
        let scanner = Scanner(home: home)
        let candidates = scanner.plan().units.filter { $0.entryID == entryID }.compactMap {
            RuleEngine.candidate(for: $0, stats: Scanner.measure($0), settings: scanner.settings, home: home)
        }
        guard !candidates.isEmpty else {
            print("\(entryID) の候補はない")
            return
        }
        for candidate in candidates {
            print("- \(candidate.title)  \(formatBytes(candidate.reclaimableBytes))  \(candidate.detail)")
        }

        let before = availableBytes()
        let purger = Purger(home: home)
        let result = purger.moveToPurge(candidates, kept: [])
        print("移した: \(result.moved.count) 件、しなかった: \(result.skipped.map(\.reason.description))")
        let (failures, elapsed) = measure { purger.emptyPurge() }
        print("削除: 失敗 \(failures) 件（\(elapsed.milliseconds)）")
        // APFS は解放を少し遅れて反映することがあるので、間をおいて何度か見る
        for seconds in [0, 2, 5, 10] {
            if seconds > 0 { Thread.sleep(forTimeInterval: Double(seconds) - Double([0, 2, 5, 10].last { $0 < seconds }!)) }
            let after = availableBytes()
            print("空き容量（\(seconds)秒後）: \(formatBytes(before)) → \(formatBytes(after))（\(formatBytes(after - before)) 増）")
        }
    }

    /// statfs の空きブロック。`volumeAvailableCapacityForImportantUsage` はシステムがしばらく値を使い回す
    static func availableBytes() -> Int64 {
        var info = statfs()
        guard statfs(home.path(percentEncoded: false), &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
