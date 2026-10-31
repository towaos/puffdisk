import Foundation
import PuffdiskCore

/// S3: カタログの各パスが実機で正しいか
enum CatalogSpike {
    /// キャッシュの場所を変える環境変数。GUI アプリからは見えないので、どれくらい使われているかを確かめる
    static let overrideVariables = [
        "XDG_CACHE_HOME", "npm_config_cache", "YARN_CACHE_FOLDER", "PNPM_HOME", "BUN_INSTALL_CACHE_DIR",
        "PIP_CACHE_DIR", "UV_CACHE_DIR", "HOMEBREW_CACHE", "CP_CACHE_DIR", "CARGO_HOME", "GOPATH", "GOMODCACHE",
        "GOCACHE", "GRADLE_USER_HOME", "PLAYWRIGHT_BROWSERS_PATH", "PUPPETEER_CACHE_DIR",
        "HF_HOME", "HF_HUB_CACHE", "TORCH_HOME",
    ]

    static func run() {
        print("== カタログの場所（ホーム: \(home.path(percentEncoded: false))）")
        var total: Int64 = 0
        for entry in CacheCatalog.entries {
            let locations = entry.resolvedLocations(home: home)
            if locations.isEmpty {
                print("- \(entry.id): なし（\(entry.paths.joined(separator: ", "))）")
                continue
            }
            for location in locations {
                let (stats, elapsed) = measure { BulkEnumerator.scan(location) }
                total += stats.reclaimableBytes
                let relative = location.path(percentEncoded: false).replacingOccurrences(of: home.path(percentEncoded: false), with: "~/")
                print("- \(entry.id): \(relative)  空く見込み \(formatBytes(stats.reclaimableBytes))"
                      + "（割り当て \(formatBytes(stats.allocatedBytes))、\(stats.files) ファイル、エラー \(stats.errors)、\(elapsed.milliseconds)）")
                if entry.unit == .perChild {
                    printChildren(of: location)
                }
            }
        }
        print("合計（空く見込み）: \(formatBytes(total))")

        print("\n== キャッシュの場所を変える環境変数（このシェルでの値）")
        let environment = ProcessInfo.processInfo.environment
        let set = overrideVariables.filter { environment[$0] != nil }
        if set.isEmpty {
            print("どれも設定されていない")
        }
        for name in set {
            print("- \(name)=\(environment[name]!)")
        }
    }

    static func printChildren(of location: URL) {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: location, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(10) {
            let stats = BulkEnumerator.scan(child)
            let latest = stats.latestModification.map { $0.formatted(date: .numeric, time: .omitted) } ?? "-"
            print("    · \(child.lastPathComponent)  \(formatBytes(stats.reclaimableBytes))  最新の更新 \(latest)")
        }
        if children.count > 10 {
            print("    · ほか \(children.count - 10) 件")
        }
    }
}
