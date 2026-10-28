import Darwin
import Foundation

/// 移動・削除の唯一の入り口（DESIGN.md 11.2）。ファイルを動かす・消すコードはここ以外に書かない。
/// M2 ではキャッシュの削除（Purge）だけを扱う。隔離・復元は M3
public struct SafeFileOps: Sendable {
    public enum Failure: Error, Hashable, Sendable {
        /// 絶対パスでない、`.`・`..` を含む、正規化されていない
        case invalidPath
        /// カタログの場所そのもの、またはその直下ではない
        case notAllowed
        /// 7.5 の触らないものに当たる（直前に判定し直した結果）
        case excluded(LocationRejection)
        case symbolicLinkInPath(String)
        case differentVolume
        case notFound
        case system(operation: String, errno: Int32)

        public var description: String {
            switch self {
            case .invalidPath: "パスの形式が正しくない"
            case .notAllowed: "削除してよい場所ではない"
            case let .excluded(rejection): rejection.description
            case let .symbolicLinkInPath(name): "途中にシンボリックリンクがある（\(name)）"
            case .differentVolume: "別のボリューム"
            case .notFound: "見つからない"
            case let .system(operation, code): "\(operation) に失敗（\(String(cString: strerror(code)))）"
            }
        }
    }

    public let home: URL
    private let policy: ExclusionPolicy
    private let configuredLocations: [ConfiguredLocation]?

    public init(home: URL, configuredLocations: [ConfiguredLocation]? = nil) {
        self.home = home.standardizedFileURL
        self.policy = ExclusionPolicy(home: home)
        self.configuredLocations = configuredLocations
    }

    /// `~/Library/Application Support/Puffdisk/`（DESIGN.md D15）
    public var supportDirectory: URL { home.appending(path: "Library/Application Support/Puffdisk", directoryHint: .isDirectory) }
    /// キャッシュの削除待ち（DESIGN.md 8.2）
    public var purgeDirectory: URL { supportDirectory.appending(path: "Purge.noindex", directoryHint: .isDirectory) }

    // MARK: - Purge

    /// キャッシュを `Purge.noindex/<ID>/` へ `rename` で移す（DESIGN.md 8.2 の 1）。
    /// 許可範囲はカタログの場所そのものか、その直下（「〜ごと」の単位）だけ
    /// - Returns: 移動先
    @discardableResult
    public func moveToPurge(_ path: URL, id: UUID) throws(Failure) -> URL {
        let target = try validatedComponents(of: path)
        guard let name = target.last else { throw .notAllowed }
        let parentComponents = Array(target.dropLast())

        // 1・2・3: カタログの場所（直前に検証し直したもの）の中で、そのものか直下
        let allowed = Scanner(home: home, configuredLocations: configuredLocations).allowedLocations()
            .compactMap(policy.relativeComponents(of:))
        guard allowed.contains(where: { $0 == target || $0 == parentComponents }) else { throw .notAllowed }
        let location = allowed.contains(target) ? target : parentComponents
        if let rejection = policy.check(location: url(location)) { throw .excluded(rejection) }

        // 4・6: 途中をシンボリックリンクに差し替えられても別の場所を操作しないよう、ファイルディスクリプタを基準にする
        let sourceFD = try openDirectory(parentComponents)
        defer { close(sourceFD) }
        let item = try statAt(sourceFD, name)

        let purgeComponents = try validatedComponents(of: purgeDirectory) + [id.uuidString]
        let destinationFD = try openDirectory(purgeComponents, creating: true)
        defer { close(destinationFD) }

        // 5: 同じボリューム
        var destination = stat()
        guard fstat(destinationFD, &destination) == 0 else { throw .system(operation: "fstat", errno: errno) }
        guard item.st_dev == destination.st_dev else { throw .differentVolume }

        guard renameatx_np(sourceFD, name, destinationFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw .system(operation: "rename", errno: errno)
        }
        return url(purgeComponents + [name])
    }

    /// `Purge.noindex/` の中身をすべて削除する（DESIGN.md 8.2 の 2・3、起動時の回復）
    /// - Returns: 消せなかった項目の数
    @discardableResult
    public func emptyPurge() -> Int {
        guard let components = try? validatedComponents(of: purgeDirectory),
              let purgeFD = try? openDirectory(components) else { return 0 }
        defer { close(purgeFD) }
        var failures = 0
        for name in Self.entries(of: purgeFD) {
            failures += Self.removeTree(parentFD: purgeFD, name: name)
        }
        return failures
    }

    // MARK: - パスの検証

    /// 1: 正規化された絶対パスで、ホームより下。ホームからの相対パスの要素を返す
    func validatedComponents(of url: URL) throws(Failure) -> [String] {
        let path = url.path(percentEncoded: false)
        guard url.isFileURL, path.hasPrefix("/") else { throw .invalidPath }
        let raw = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let components = raw.last == "" ? raw.dropLast() : raw[...]
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw .invalidPath }
        guard let relative = policy.relativeComponents(of: url), !relative.isEmpty else { throw .notAllowed }
        return relative
    }

    /// ホームを開き、その下を1要素ずつ `O_NOFOLLOW` で開く。ホームより上のシンボリックリンクはたどる。
    /// 返したファイルディスクリプタは呼び出し側が閉じる
    func openDirectory(_ components: [String], creating: Bool = false) throws(Failure) -> Int32 {
        var fd = open(home.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw .system(operation: "open", errno: errno) }
        for name in components {
            var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, creating {
                // アプリ専用のフォルダは 0700 で作る（DESIGN.md 11.4）
                if mkdirat(fd, name, 0o700) == 0 || errno == EEXIST {
                    next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            let code = errno
            if next < 0 {
                var info = stat()
                let isLink = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFLNK
                close(fd)
                if isLink { throw .symbolicLinkInPath(name) }
                throw code == ENOENT ? .notFound : .system(operation: "open", errno: code)
            }
            close(fd)
            fd = next
        }
        return fd
    }

    private func url(_ components: [String]) -> URL {
        components.reduce(home) { $0.appending(path: $1) }
    }

    private func statAt(_ fd: Int32, _ name: String) throws(Failure) -> stat {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT ? .notFound : .system(operation: "stat", errno: errno)
        }
        return info
    }

    // MARK: - 削除

    /// シンボリックリンクはたどらず、リンク自体を消す（7）。読み取り専用のフォルダは書き込み権限を付けてから消す（8.2）
    /// - Returns: 消せなかった項目の数
    static func removeTree(parentFD: Int32, name: String) -> Int {
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? 0 : 1 }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return unlinkat(parentFD, name, 0) == 0 || errno == ENOENT ? 0 : 1
        }

        // 中を読み、項目を消すには、フォルダに読み・書き・実行の権限が要る
        if info.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(parentFD, name, (info.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 1 }
        var failures = 0
        for child in entries(of: fd) {
            failures += removeTree(parentFD: fd, name: child)
        }
        close(fd)
        if unlinkat(parentFD, name, AT_REMOVEDIR) != 0, errno != ENOENT { failures += 1 }
        return failures
    }

    /// フォルダの項目名（`.` と `..` を除く）
    static func entries(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
