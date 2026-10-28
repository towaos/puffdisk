import Foundation

/// 候補のカテゴリ（DESIGN.md 7.1）
public enum CandidateCategory: String, Sendable {
    case cache
    case review
}

/// カタログの1項目（DESIGN.md 7.2）
public struct CacheCatalogEntry: Identifiable, Sendable {
    public enum Unit: Equatable, Sendable {
        /// 場所全体を1つの候補にする
        case whole
        /// サブフォルダを1つずつ候補にする
        case perChild
    }

    /// 「〜ごと」の単位の日数の基準（DESIGN.md 7.6）
    public enum AgeRule: Equatable, Sendable {
        /// DerivedData の未ビルド日数（7.3）
        case derivedDataBuild
        /// DeviceSupport・JetBrains の未更新日数
        case staleToolData
    }

    public let id: String
    public let name: String
    public let group: String
    /// ホームからの相対パス。1つの要素に `*` を1つまで含められる（例: `Library/Developer/Xcode/*DeviceSupport`）
    public let paths: [String]
    public let unit: Unit
    public let minimumBytes: Int64
    public let ageRule: AgeRule?
    public let category: CandidateCategory
    public let selectedByDefault: Bool
    public let reason: String

    public init(
        id: String, name: String, group: String, paths: [String],
        unit: Unit = .whole, minimumBytes: Int64 = 100_000_000, ageRule: AgeRule? = nil,
        category: CandidateCategory = .cache, selectedByDefault: Bool = true, reason: String
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.paths = paths
        self.unit = unit
        self.minimumBytes = minimumBytes
        self.ageRule = ageRule
        self.category = category
        self.selectedByDefault = selectedByDefault
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
        .init(id: "maven", name: "Maven", group: "パッケージ", paths: [".m2/repository"],
              category: .review, selectedByDefault: false,
              reason: "mvn install したローカルの成果物は取り直せない"),
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
              unit: .perChild, minimumBytes: 0, ageRule: .derivedDataBuild,
              reason: "次回ビルドで作り直される"),
        .init(id: "device-support", name: "Xcode DeviceSupport", group: "Xcode", paths: ["Library/Developer/Xcode/*DeviceSupport"],
              unit: .perChild, minimumBytes: 0, ageRule: .staleToolData,
              reason: "実機を接続すると作り直される"),
        .init(id: "simulator-caches", name: "Simulator キャッシュ", group: "Xcode", paths: ["Library/Developer/CoreSimulator/Caches"],
              reason: "必要に応じて作り直される"),
        .init(id: "jetbrains", name: "JetBrains", group: "IDE", paths: ["Library/Caches/JetBrains"],
              unit: .perChild, minimumBytes: 0, ageRule: .staleToolData,
              reason: "古いバージョンの IDE のキャッシュ"),
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
