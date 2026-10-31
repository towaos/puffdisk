import Foundation

/// カタログの1項目（DESIGN.md 7.2）
public struct CacheCatalogEntry: Identifiable, Hashable, Sendable {
    public enum Unit: Hashable, Sendable {
        /// 場所全体を1つの候補にする
        case whole
        /// サブフォルダを1つずつ候補にする（直下のファイルと `.` で始まるフォルダは対象にしない）
        case perChild
        /// Xcode DerivedData。プロジェクトごとと、共有キャッシュをまとめた1つ（DESIGN.md 7.3）
        case derivedData
        /// すべての場所をまとめて1つの候補にする（同じアプリのキャッシュ・ログ・更新ファイル）。`*` は使わない
        case combined
    }

    /// 「〜ごと」の単位の日数の基準（DESIGN.md 7.6）
    public enum AgeRule: Hashable, Sendable {
        /// DeviceSupport・JetBrains の未更新日数
        case staleToolData
        /// ログの未更新日数
        case staleLogs
    }

    public let id: String
    public let name: String
    public let group: String
    /// ホームからの相対パス。1つの要素に `*` を1つまで含められる（例: `Library/Developer/Xcode/*DeviceSupport`）
    public let paths: [String]
    public let unit: Unit
    public let minimumBytes: Int64
    public let ageRule: AgeRule?
    public let selectedByDefault: Bool
    /// このキャッシュを使うアプリの Bundle ID。どれかが起動中なら削除しない（DESIGN.md 7.7）
    public let appBundleIDs: [String]
    public let reason: String

    public init(
        id: String, name: String, group: String, paths: [String],
        unit: Unit = .whole, minimumBytes: Int64 = 100_000_000, ageRule: AgeRule? = nil,
        selectedByDefault: Bool = true, appBundleIDs: [String] = [], reason: String
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.paths = paths
        self.unit = unit
        self.minimumBytes = minimumBytes
        self.ageRule = ageRule
        self.selectedByDefault = selectedByDefault
        self.appBundleIDs = appBundleIDs
        self.reason = reason
    }

    /// 実在する場所の一覧。`*` はその階層のフォルダ名と照合する
    public func resolvedLocations(home: URL, fileManager: FileManager = .default) -> [URL] {
        paths.flatMap { path in
            Self.resolve(path.split(separator: "/").map(String.init)[...], from: home, fileManager: fileManager)
        }
    }

    private static func resolve(_ components: ArraySlice<String>, from base: URL, fileManager: FileManager) -> [URL] {
        guard let first = components.first else {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: base.path(percentEncoded: false), isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? [base] : []
        }
        let rest = components.dropFirst()
        guard first.contains("*") else {
            return resolve(rest, from: base.appending(path: first, directoryHint: .isDirectory), fileManager: fileManager)
        }

        let pattern = first.split(separator: "*", omittingEmptySubsequences: false)
        let (prefix, suffix) = (String(pattern[0]), pattern.count > 1 ? String(pattern[1]) : "")
        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path(percentEncoded: false)) else { return [] }
        return names
            .filter { $0.count >= prefix.count + suffix.count && $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .sorted()
            .flatMap { resolve(rest, from: base.appending(path: $0, directoryHint: .isDirectory), fileManager: fileManager) }
    }
}

/// アプリに組み込むキャッシュの一覧（DESIGN.md 7.2）。パスは macOS での既定値
public enum CacheCatalog {
    static let gigabyte: Int64 = 1_000_000_000
    /// 日数で判定する「〜ごと」の単位の下限。これより小さいものは一覧に並べても意味がない
    static let megabyte: Int64 = 1_000_000
    static let xcode = ["com.apple.dt.Xcode"]

    static let browserReason = "閲覧すると作り直される。履歴・ログイン状態は消えない"
    static let appReason = "キャッシュ・ログ・更新ファイル。起動すると作り直され、更新はもう一度ダウンロードされる"
    static let updateReason = "ダウンロード済みの更新ファイル。必要ならもう一度ダウンロードされる"

    /// Electron（Chromium）アプリが `~/Library/Application Support/<アプリ>/` に作るキャッシュとログ。
    /// `Service Worker`・`IndexedDB`・`Local Storage` などはオフライン用のデータやログイン状態を含むので入れない
    static func electronCaches(_ base: String) -> [String] {
        ["Cache", "Code Cache", "GPUCache", "GPUPersistentCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
         "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "logs"].map { "\(base)/\($0)" }
    }

    public static let entries: [CacheCatalogEntry] = [
        .init(id: "npm", name: "npm", group: "パッケージ", paths: [".npm/_cacache"],
              reason: "次回 install 時に必要な分だけ再取得"),
        .init(id: "yarn", name: "Yarn", group: "パッケージ", paths: ["Library/Caches/Yarn", ".yarn/berry/cache"],
              reason: "次回 install 時に必要な分だけ再取得"),
        .init(id: "pnpm", name: "pnpm", group: "パッケージ", paths: ["Library/pnpm/store"],
              reason: "次回 install 時に必要な分だけ再取得。node_modules から使われている分は空かない"),
        .init(id: "bun", name: "Bun", group: "パッケージ", paths: [".bun/install/cache"],
              reason: "次回 install 時に再取得"),
        .init(id: "pip", name: "pip", group: "パッケージ", paths: ["Library/Caches/pip"],
              reason: "次回 install 時に再取得"),
        .init(id: "uv", name: "uv", group: "パッケージ", paths: [".cache/uv"],
              reason: "次回 install 時に再取得"),
        .init(id: "homebrew", name: "Homebrew", group: "パッケージ", paths: ["Library/Caches/Homebrew"],
              reason: "ダウンロード済みのファイル。インストール済みのものには影響しない"),
        .init(id: "cocoapods", name: "CocoaPods", group: "パッケージ", paths: ["Library/Caches/CocoaPods"],
              reason: "次回 pod install 時に再取得"),
        .init(id: "cargo", name: "Cargo", group: "パッケージ",
              paths: [".cargo/registry/cache", ".cargo/registry/src", ".cargo/git"],
              reason: "次回ビルド時に再取得"),
        .init(id: "go", name: "Go", group: "パッケージ", paths: ["Library/Caches/go-build", "go/pkg/mod"],
              reason: "次回ビルド時に再取得"),
        .init(id: "gradle", name: "Gradle", group: "パッケージ", paths: [".gradle/caches", ".gradle/wrapper/dists"],
              reason: "次回ビルド時に再取得"),
        .init(id: "playwright", name: "Playwright", group: "ブラウザ", paths: ["Library/Caches/ms-playwright"],
              reason: "必要なら playwright install で再取得"),
        .init(id: "puppeteer", name: "Puppeteer", group: "ブラウザ", paths: [".cache/puppeteer"],
              reason: "次回 install 時に再取得"),
        .init(id: "node-gyp", name: "node-gyp", group: "パッケージ", paths: ["Library/Caches/node-gyp"],
              reason: "ネイティブモジュールのビルド時に再取得"),
        .init(id: "huggingface", name: "Hugging Face", group: "機械学習モデル", paths: [".cache/huggingface/hub"],
              unit: .perChild, minimumBytes: gigabyte, selectedByDefault: false,
              reason: "再ダウンロードに時間がかかる"),
        .init(id: "torch", name: "PyTorch", group: "機械学習モデル", paths: [".cache/torch"],
              selectedByDefault: false,
              reason: "再ダウンロードに時間がかかる"),
        .init(id: "derived-data", name: "Xcode DerivedData", group: "Xcode", paths: ["Library/Developer/Xcode/DerivedData"],
              unit: .derivedData, minimumBytes: megabyte,
              reason: "次回ビルドで作り直される"),
        .init(id: "device-support", name: "Xcode DeviceSupport", group: "Xcode", paths: ["Library/Developer/Xcode/*DeviceSupport"],
              unit: .perChild, minimumBytes: megabyte, ageRule: .staleToolData,
              reason: "実機を接続すると作り直される"),
        .init(id: "simulator-caches", name: "Simulator キャッシュ", group: "Xcode", paths: ["Library/Developer/CoreSimulator/Caches"],
              reason: "必要に応じて作り直される"),
        .init(id: "jetbrains", name: "JetBrains", group: "IDE", paths: ["Library/Caches/JetBrains"],
              unit: .perChild, minimumBytes: megabyte, ageRule: .staleToolData,
              reason: "古いバージョンの IDE のキャッシュ"),
        .init(id: "xcode-cache", name: "Xcode のキャッシュ", group: "Xcode", paths: ["Library/Caches/com.apple.dt.Xcode"],
              appBundleIDs: xcode,
              reason: "Xcode が必要に応じて作り直す"),
        .init(id: "xcode-previews", name: "SwiftUI プレビュー", group: "Xcode", paths: ["Library/Developer/Xcode/UserData/Previews"],
              appBundleIDs: xcode,
              reason: "プレビュー用のシミュレーター。次回プレビュー時に作り直される"),
        .init(id: "xctest-devices", name: "テスト用シミュレーター", group: "Xcode", paths: ["Library/Developer/XCTestDevices"],
              appBundleIDs: xcode,
              reason: "並列テスト用に複製したシミュレーター。次回テスト時に作り直される"),
        .init(id: "xcode-documentation", name: "Xcode ドキュメントのキャッシュ", group: "Xcode",
              paths: ["Library/Developer/Xcode/DocumentationCache"],
              appBundleIDs: xcode,
              reason: "必要に応じて作り直される"),

        // Chromium 系は `~/Library/Application Support/<製品>` のプロファイルに対し、`~/Library/Caches/<製品>` にキャッシュを置く
        .init(id: "chrome", name: "Google Chrome", group: "ブラウザ", paths: ["Library/Caches/Google/Chrome"],
              appBundleIDs: ["com.google.Chrome"], reason: browserReason),
        .init(id: "edge", name: "Microsoft Edge", group: "ブラウザ", paths: ["Library/Caches/Microsoft Edge"],
              appBundleIDs: ["com.microsoft.edgemac"], reason: browserReason),
        .init(id: "brave", name: "Brave", group: "ブラウザ", paths: ["Library/Caches/BraveSoftware/Brave-Browser"],
              appBundleIDs: ["com.brave.Browser"], reason: browserReason),
        .init(id: "arc", name: "Arc", group: "ブラウザ", paths: ["Library/Caches/Arc/User Data"],
              appBundleIDs: ["company.thebrowser.Browser"], reason: browserReason),
        .init(id: "vivaldi", name: "Vivaldi", group: "ブラウザ", paths: ["Library/Caches/Vivaldi"],
              appBundleIDs: ["com.vivaldi.Vivaldi"], reason: browserReason),
        .init(id: "opera", name: "Opera", group: "ブラウザ", paths: ["Library/Caches/com.operasoftware.Opera"],
              appBundleIDs: ["com.operasoftware.Opera"], reason: browserReason),
        .init(id: "opera-gx", name: "Opera GX", group: "ブラウザ", paths: ["Library/Caches/com.operasoftware.OperaGX"],
              appBundleIDs: ["com.operasoftware.OperaGX"], reason: browserReason),
        .init(id: "chromium", name: "Chromium", group: "ブラウザ", paths: ["Library/Caches/Chromium"],
              appBundleIDs: ["org.chromium.Chromium"], reason: browserReason),
        .init(id: "firefox", name: "Firefox", group: "ブラウザ",
              paths: ["Library/Caches/Firefox/Profiles", "Library/Caches/Mozilla/updates/Applications/Firefox"],
              unit: .combined, appBundleIDs: ["org.mozilla.firefox"],
              reason: "キャッシュと更新ファイル。閲覧すると作り直され、更新はもう一度ダウンロードされる。履歴・ログイン状態は消えない"),
        .init(id: "zen", name: "Zen", group: "ブラウザ",
              paths: ["Library/Caches/zen/Profiles", "Library/Caches/Mozilla/updates/Applications/Zen"],
              unit: .combined, appBundleIDs: ["app.zen-browser.zen"],
              reason: "キャッシュと更新ファイル。閲覧すると作り直され、更新はもう一度ダウンロードされる。履歴・ログイン状態は消えない"),

        .init(id: "slack", name: "Slack", group: "アプリ",
              paths: electronCaches("Library/Application Support/Slack") + ["Library/Caches/com.tinyspeck.slackmacgap.ShipIt"],
              unit: .combined, appBundleIDs: ["com.tinyspeck.slackmacgap"],
              reason: appReason),
        .init(id: "notion", name: "Notion", group: "アプリ",
              paths: electronCaches("Library/Application Support/Notion") + ["Library/Caches/notion.id.ShipIt", "Library/Caches/notion-updater"],
              unit: .combined, appBundleIDs: ["notion.id"],
              reason: appReason),
        .init(id: "vscode", name: "Visual Studio Code", group: "アプリ",
              paths: electronCaches("Library/Application Support/Code")
                  + ["Library/Application Support/Code/CachedData", "Library/Application Support/Code/CachedExtensionVSIXs",
                     "Library/Caches/com.microsoft.VSCode.ShipIt"],
              unit: .combined, appBundleIDs: ["com.microsoft.VSCode"],
              reason: "キャッシュ・ログ・更新ファイル。起動すると作り直され、更新はもう一度ダウンロードされる。拡張機能と設定は消えない"),
        .init(id: "cursor", name: "Cursor", group: "アプリ",
              paths: electronCaches("Library/Application Support/Cursor")
                  + ["Library/Application Support/Cursor/CachedData", "Library/Application Support/Cursor/CachedExtensionVSIXs",
                     "Library/Caches/cursor-updater"],
              unit: .combined, appBundleIDs: ["com.todesktop.230313mzl4w4u92"],
              reason: "キャッシュ・ログ・更新ファイル。起動すると作り直され、更新はもう一度ダウンロードされる。拡張機能と設定は消えない"),
        .init(id: "github-desktop", name: "GitHub Desktop", group: "アプリ",
              paths: electronCaches("Library/Application Support/GitHub Desktop") + ["Library/Caches/com.github.GitHubClient.ShipIt"],
              unit: .combined, appBundleIDs: ["com.github.GitHubClient"],
              reason: appReason),
        .init(id: "claude", name: "Claude", group: "アプリ", paths: electronCaches("Library/Application Support/Claude"),
              unit: .combined, appBundleIDs: ["com.anthropic.claudefordesktop"],
              reason: "キャッシュとログ。起動すると作り直される"),
        .init(id: "figma", name: "Figma", group: "アプリ", paths: ["Library/Caches/com.figma.Desktop.ShipIt"],
              appBundleIDs: ["com.figma.Desktop"],
              reason: updateReason),

        .init(id: "logs", name: "ログ", group: "ログ", paths: ["Library/Logs"],
              unit: .perChild, minimumBytes: megabyte, ageRule: .staleLogs,
              reason: "アプリの動作には使われない"),

        .init(id: "ios-updates", name: "iOS・iPadOS のアップデート", group: "iPhone・iPad",
              paths: ["Library/iTunes/iPhone Software Updates", "Library/iTunes/iPad Software Updates"],
              reason: "必要になればもう一度ダウンロードされる"),
    ]

    /// カタログの場所の中にあっても触らないもの（DESIGN.md 7.2）。テストで重なりがないことを確かめる
    public static let protectedPaths: [String] = [
        ".cargo/bin",
        ".cargo/config.toml",
        ".gradle/gradle.properties",
        "Library/Developer/Xcode/Archives",
        "Library/Developer/CoreSimulator/Devices",
    ]
}
