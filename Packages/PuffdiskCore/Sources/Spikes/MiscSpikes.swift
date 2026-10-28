import Foundation

/// S6: クラウド同期の判定
enum UbiquitySpike {
    static let syncMarkers = [".dropbox", ".stfolder", ".sync", ".tresorit"]

    static func run(paths: [String]) {
        var urls = paths.map(expandTilde)
        if urls.isEmpty {
            urls = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs", "Dropbox"]
                .map { home.appending(path: $0, directoryHint: .isDirectory) }
            let cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
            urls += (try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil)) ?? []
        }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .volumeIdentifierKey, .volumeNameKey, .isSymbolicLinkKey]
        for url in urls {
            let path = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                print("- \(path): なし")
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: keys)
                let markers = syncMarkers.filter { FileManager.default.fileExists(atPath: url.appending(path: $0).path(percentEncoded: false)) }
                print("- \(path): isUbiquitousItem=\(values.isUbiquitousItem.map(String.init) ?? "nil")"
                      + "  ボリューム=\(values.volumeName ?? "?")"
                      + "  シンボリックリンク=\(values.isSymbolicLink ?? false)"
                      + "  同期の目印=\(markers.isEmpty ? "なし" : markers.joined(separator: ","))")
            } catch {
                print("- \(path): 読めない（\(error.localizedDescription)）")
            }
        }
    }
}

/// S8: .noindex フォルダが Spotlight の索引から外れるか
enum NoIndexSpike {
    static let base = home.appending(path: "Library/Application Support/Puffdisk-spike", directoryHint: .isDirectory)
    static let variants = ["Control", "Test.noindex", "NeverIndex"]

    static func run(arguments: [String]) {
        switch arguments.first {
        case "setup": setup()
        case "check": check()
        case "clean":
            try? FileManager.default.removeItem(at: base)
            print("削除しました: \(base.path(percentEncoded: false))")
        default:
            print(usage)
            exit(64)
        }
    }

    static func setup() {
        let token = UUID().uuidString.prefix(8).lowercased()
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try token.write(to: base.appending(path: "token.txt"), atomically: true, encoding: .utf8)
            for variant in variants {
                let directory = base.appending(path: variant, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if variant == "NeverIndex" {
                    FileManager.default.createFile(atPath: directory.appending(path: ".metadata_never_index").path(percentEncoded: false), contents: nil)
                }
                try "puffdisk spike \(token)".write(to: directory.appending(path: "puffdisk-spike-\(token)-\(variant).txt"), atomically: true, encoding: .utf8)
            }
            print("作成しました（トークン \(token)）。数分おいてから `noindex check` を実行してください")
        } catch {
            print("作成に失敗: \(error)")
            exit(1)
        }
    }

    static func check() {
        guard let token = try? String(contentsOf: base.appending(path: "token.txt"), encoding: .utf8) else {
            print("先に `noindex setup` を実行してください")
            exit(1)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdfind")
        process.arguments = ["-name", "puffdisk-spike-\(token)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for variant in variants {
            let found = output.contains("-\(variant).txt")
            print("- \(variant): \(found ? "索引されている" : "索引されていない")")
        }
    }
}

/// S10: 読み取り専用のフォルダ（Go のモジュールキャッシュ相当）の削除
enum ReadOnlyDeleteSpike {
    static func run() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "readonly-\(UUID().uuidString)", directoryHint: .isDirectory)
        let leaf = root.appending(path: "mod/example.com/pkg@v1.0.0", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: leaf, withIntermediateDirectories: true)
            try "package pkg".write(to: leaf.appending(path: "pkg.go"), atomically: true, encoding: .utf8)
            // go のモジュールキャッシュと同じく、ファイル 0444・フォルダ 0555 にする
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: leaf.appending(path: "pkg.go").path(percentEncoded: false))
            for directory in [leaf, leaf.deletingLastPathComponent(), root.appending(path: "mod")] {
                try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
            }
        } catch {
            print("準備に失敗: \(error)")
            exit(1)
        }

        do {
            try fileManager.removeItem(at: root)
            print("そのまま削除できた（権限の変更は不要）")
            return
        } catch {
            print("そのままでは削除できない: \((error as NSError).localizedDescription)")
        }

        // フォルダに書き込み権限を付けてから消す（DESIGN.md 8.2）
        let directories = [root.appending(path: "mod"), leaf.deletingLastPathComponent(), leaf]
        for directory in directories {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        }
        do {
            try fileManager.removeItem(at: root)
            print("フォルダに書き込み権限を付けたら削除できた")
        } catch {
            print("権限を付けても削除できない: \(error)")
        }
    }
}
