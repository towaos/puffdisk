import Foundation

/// テスト用のホームフォルダ。一時フォルダの下に作り、シンボリックリンクを解決したパスを使う
struct TestHome {
    let url: URL
    private let fileManager = FileManager.default

    init() throws {
        let base = fileManager.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appending(path: "home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? fileManager.removeItem(at: url)
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let directory = url.appending(path: path, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, contents: Data? = nil) throws -> URL {
        let file = url.appending(path: path)
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents ?? Data(repeating: 0x61, count: bytes)).write(to: file)
        return file
    }

    func setModified(_ path: String, daysAgo: Double) throws {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.appending(path: path).path(percentEncoded: false))
    }

    func path(_ relative: String) -> URL {
        url.appending(path: relative)
    }
}
