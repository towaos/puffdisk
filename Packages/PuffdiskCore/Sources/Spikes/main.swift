import Foundation
import PuffdiskCore

// M0 検証スパイク（DESIGN.md 13.1）。macOS の許可ダイアログが絡む S1・S2 はアプリのデバッグ画面で行う

let usage = """
使い方: puffdisk-spikes <コマンド>
  scan                            M1  候補一覧（アプリと同じ判定）
  purge <種類> --yes                M2  指定した種類のキャッシュだけを削除し、空き容量の増え方を見る
  catalog                         S3  カタログの各場所の有無とサイズ、場所を変える環境変数
  bench <フォルダ>...              S5  getattrlistbulk と FileManager の列挙の速さ
  fsevents watch <フォルダ> [秒]     S4  変化を表示し、最後のイベントIDを出す
  fsevents replay <フォルダ> <ID> [秒]  S4  指定IDからの変化を再生する
  ubiquity [パス]...                S6  クラウド同期の判定
  noindex setup|check|clean       S8  .noindex フォルダが Spotlight の索引から外れるか
  readonly                        S10 読み取り専用のフォルダ（Go のモジュールキャッシュ相当）の削除
"""

// MARK: - 共通

let home = FileManager.default.homeDirectoryForCurrentUser

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func expandTilde(_ path: String) -> URL {
    URL(filePath: (path as NSString).expandingTildeInPath)
}

func measure<T>(_ body: () -> T) -> (T, Duration) {
    let clock = ContinuousClock()
    var result: T!
    let elapsed = clock.measure { result = body() }
    return (result, elapsed)
}

extension Duration {
    var milliseconds: String {
        let (seconds, attoseconds) = components
        return String(format: "%.0fms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}

// MARK: - 実行（トップレベルの変数は上から順に初期化されるので最後に置く）

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "scan": ScanCommand.run()
case "purge": PurgeCommand.run(arguments: Array(arguments.dropFirst()))
case "catalog": CatalogSpike.run()
case "bench": BenchSpike.run(paths: Array(arguments.dropFirst()))
case "fsevents": FSEventsSpike.run(arguments: Array(arguments.dropFirst()))
case "ubiquity": UbiquitySpike.run(paths: Array(arguments.dropFirst()))
case "noindex": NoIndexSpike.run(arguments: Array(arguments.dropFirst()))
case "readonly": ReadOnlyDeleteSpike.run()
default:
    print(usage)
    exit(64)
}
