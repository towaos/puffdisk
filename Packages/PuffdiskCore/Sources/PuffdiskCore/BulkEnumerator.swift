import Darwin
import Foundation

/// フォルダ以下の集計結果（DESIGN.md 9.3）
public struct TreeStats: Equatable, Sendable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var others = 0
    /// ディスク上の割り当てサイズの合計（ハードリンクは1回だけ数える）
    public var allocatedBytes: Int64 = 0
    /// 空く見込み量。ハードリンクは、すべてのリンクがこのフォルダの中にあるときだけ数える
    public var reclaimableBytes: Int64 = 0
    /// 中身の最新の更新日
    public var latestModification: Date?
    public var errors = 0

    public init() {}
}

/// ハードリンクを考慮した集計
struct HardLinkTally {
    private var pending: [UInt64: (links: UInt32, seen: UInt32, bytes: Int64)] = [:]

    /// - Returns: 割り当てサイズに足す量（同じファイルの2つ目以降のリンクは 0）
    mutating func add(fileID: UInt64, linkCount: UInt32, bytes: Int64) -> Int64 {
        guard linkCount > 1 else { return bytes }
        if var entry = pending[fileID] {
            entry.seen += 1
            pending[fileID] = entry
            return 0
        }
        pending[fileID] = (linkCount, 1, bytes)
        return bytes
    }

    /// すべてのリンクを見つけたファイルの合計
    var completeBytes: Int64 {
        pending.values.reduce(0) { $0 + ($1.seen >= $1.links ? $1.bytes : 0) }
    }
}

/// `getattrlistbulk` で1回のシステムコールごとに複数の項目の属性を取る列挙（DESIGN.md 9.3）。
/// シンボリックリンクはたどらない
public enum BulkEnumerator {
    private enum Attr {
        static let commonName: UInt32 = 0x0000_0001
        static let commonObjType: UInt32 = 0x0000_0008
        static let commonModTime: UInt32 = 0x0000_0400
        static let commonFileID: UInt32 = 0x0200_0000
        static let commonError: UInt32 = 0x2000_0000
        static let commonReturnedAttrs: UInt32 = 0x8000_0000
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
    }

    private enum ObjectType {
        static let regular: UInt32 = 1
        static let directory: UInt32 = 2
        static let symlink: UInt32 = 5
    }

    private static let bufferSize = 256 * 1024

    public static func scan(_ root: URL) -> TreeStats {
        var stats = TreeStats()
        var links = HardLinkTally()
        var singleLinkBytes: Int64 = 0

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.commonReturnedAttrs | Attr.commonName | Attr.commonError
            | Attr.commonObjType | Attr.commonModTime | Attr.commonFileID
        request.fileattr = Attr.fileLinkCount | Attr.fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var pendingDirectories = [root.path(percentEncoded: false)]
        while let directory = pendingDirectories.popLast() {
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                stats.errors += 1
                continue
            }
            defer { close(fd) }

            while true {
                let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
                if count < 0 { stats.errors += 1 }
                if count <= 0 { break }

                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let length = entry.loadUnaligned(as: UInt32.self)
                    defer { entry += Int(length) }

                    var field = entry + MemoryLayout<UInt32>.size
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field += MemoryLayout<attribute_set_t>.size

                    // ATTR_CMN_ERROR は返却属性の直後に来る。それ以外はビットの小さい順に並ぶ
                    if returned.commonattr & Attr.commonError != 0 {
                        let error = field.loadUnaligned(as: UInt32.self)
                        field += MemoryLayout<UInt32>.size
                        if error != 0 {
                            stats.errors += 1
                            continue
                        }
                    }
                    var name = ""
                    if returned.commonattr & Attr.commonName != 0 {
                        let reference = field.loadUnaligned(as: attrreference_t.self)
                        name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                        field += MemoryLayout<attrreference_t>.size
                    }
                    var type: UInt32 = 0
                    if returned.commonattr & Attr.commonObjType != 0 {
                        type = field.loadUnaligned(as: UInt32.self)
                        field += MemoryLayout<UInt32>.size
                    }
                    if returned.commonattr & Attr.commonModTime != 0 {
                        let time = field.loadUnaligned(as: timespec.self)
                        field += MemoryLayout<timespec>.size
                        let date = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
                        if stats.latestModification.map({ date > $0 }) ?? true {
                            stats.latestModification = date
                        }
                    }
                    var fileID: UInt64 = 0
                    if returned.commonattr & Attr.commonFileID != 0 {
                        fileID = field.loadUnaligned(as: UInt64.self)
                        field += MemoryLayout<UInt64>.size
                    }
                    var linkCount: UInt32 = 1
                    if returned.fileattr & Attr.fileLinkCount != 0 {
                        linkCount = field.loadUnaligned(as: UInt32.self)
                        field += MemoryLayout<UInt32>.size
                    }
                    var allocated: Int64 = 0
                    if returned.fileattr & Attr.fileAllocSize != 0 {
                        allocated = field.loadUnaligned(as: Int64.self)
                        field += MemoryLayout<Int64>.size
                    }

                    switch type {
                    case ObjectType.directory:
                        stats.directories += 1
                        pendingDirectories.append(directory + "/" + name)
                    case ObjectType.regular:
                        stats.files += 1
                        let added = links.add(fileID: fileID, linkCount: linkCount, bytes: allocated)
                        stats.allocatedBytes += added
                        if linkCount <= 1 { singleLinkBytes += added }
                    case ObjectType.symlink:
                        stats.symlinks += 1
                    default:
                        stats.others += 1
                    }
                }
            }
        }

        stats.reclaimableBytes = singleLinkBytes + links.completeBytes
        return stats
    }
}
