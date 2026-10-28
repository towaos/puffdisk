import CoreServices
import Foundation

/// S4: FSEvents の監視と「指定IDからの再生」
enum FSEventsSpike {
    static func run(arguments: [String]) {
        guard arguments.count >= 2 else {
            print(usage)
            exit(64)
        }
        let path = expandTilde(arguments[1]).path(percentEncoded: false)
        switch arguments[0] {
        case "watch":
            let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 20 : 20
            start(path: path, since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow), seconds: seconds)
        case "replay":
            guard arguments.count > 2, let since = UInt64(arguments[2]) else {
                print("イベントIDを指定してください")
                exit(64)
            }
            let seconds = arguments.count > 3 ? Double(arguments[3]) ?? 5 : 5
            start(path: path, since: since, seconds: seconds)
        default:
            print(usage)
            exit(64)
        }
    }

    static func start(path: String, since: FSEventStreamEventId, seconds: Double) {
        let callback: FSEventStreamCallback = { _, _, count, paths, flags, ids in
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            for index in 0..<count {
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    print("--- ここまでが過去の変化（HistoryDone）。ID \(ids[index])")
                    continue
                }
                print("\(ids[index])  \(String(format: "0x%08x", flags[index]))  \(paths[index])")
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, nil, [path] as CFArray, since, 0.5, flags) else {
            print("FSEventStreamCreate に失敗")
            exit(1)
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            print("FSEventStreamStart に失敗")
            exit(1)
        }
        print("監視開始: \(path)  開始時点のイベントID \(FSEventsGetCurrentEventId())  \(Int(seconds))秒")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            FSEventStreamFlushSync(stream)
            print("終了。最後のイベントID \(FSEventStreamGetLatestEventId(stream))")
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            exit(0)
        }
        dispatchMain()
    }
}
