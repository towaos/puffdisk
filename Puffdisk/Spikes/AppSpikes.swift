import CoreServices
import Darwin
import Foundation

/// アプリとして動かさないと確かめられない検証スパイク（DESIGN.md 13.1）。
/// Downloads へのアクセスはアプリ単位で macOS の許可（TCC）が要るため、CLI ではなくここで行う
enum AppSpikes {

    /// S1: Downloads 内のファイルの kMDItemLastUsedDate を取得できるか
    static func lastUsedDates(limit: Int = 50) -> String {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            return "S1: Downloads を読めない（\(describe(error))）"
        }

        var withDate = 0
        var samples: [String] = []
        for url in items.prefix(limit) {
            let item = MDItemCreateWithURL(nil, url as CFURL)
            let date = item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
            if let date {
                withDate += 1
                if samples.count < 3 {
                    samples.append("\(url.lastPathComponent): \(date.formatted(date: .numeric, time: .omitted))")
                }
            }
        }
        let checked = min(items.count, limit)
        return "S1: Downloads の \(checked) 件中 \(withDate) 件で最終使用日を取得できた\n" + samples.map { "  · \($0)" }.joined(separator: "\n")
    }

    /// S2: Downloads から Application Support/Puffdisk へ rename で移動・復元できるか
    static func quarantineRoundTrip() -> String {
        var log = ["S2:"]
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
        let quarantine = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Puffdisk/Spike.noindex", directoryHint: .isDirectory)
        let name = "puffdisk-spike-\(UUID().uuidString.prefix(8)).txt"
        let original = downloads.appending(path: name)
        let moved = quarantine.appending(path: name)

        do {
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "Puffdisk の検証用ファイル。消してかまいません".write(to: original, atomically: true, encoding: .utf8)
            log.append("  · Downloads にテストファイルを作成")
        } catch {
            return (log + ["  · 準備に失敗（\(describe(error))）"]).joined(separator: "\n")
        }
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: quarantine)
        }

        let sourceVolume = try? downloads.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let destinationVolume = try? quarantine.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        log.append("  · 同じボリューム: \(sourceVolume != nil && sourceVolume == destinationVolume)")

        let permissions = (try? FileManager.default.attributesOfItem(atPath: quarantine.path(percentEncoded: false))[.posixPermissions] as? Int) ?? 0
        log.append("  · 隔離フォルダの権限: \(String(permissions, radix: 8))")

        log.append("  · 隔離（rename）: \(rename(from: original, to: moved))")
        log.append("  · 元の場所から消えた: \(!FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))")
        log.append("  · 復元（rename）: \(rename(from: moved, to: original))")
        log.append("  · 元の場所に戻った: \(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))")
        return log.joined(separator: "\n")
    }

    private static func rename(from source: URL, to destination: URL) -> String {
        Darwin.rename(source.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0
            ? "成功"
            : "失敗（errno \(errno): \(String(cString: strerror(errno)))）"
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.domain) \($0.code)" } ?? ""
        return "\(nsError.domain) \(nsError.code)\(underlying)"
    }
}

/// スパイクの結果を Claude や開発者が読めるようにファイルにも残す
enum SpikeLogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Puffdisk/spike-results.log")

    static func append(_ message: String) {
        let line = "[\(Date().formatted(.iso8601))] \(message)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
