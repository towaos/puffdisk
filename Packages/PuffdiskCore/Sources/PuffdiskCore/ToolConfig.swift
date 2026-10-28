import Foundation

/// ツールの設定ファイルで変えられたキャッシュの場所（DESIGN.md 7.2）。
/// コマンドは実行せず（D13）、設定ファイルを読むだけで決める
public struct ConfiguredLocation: Equatable, Sendable {
    public let entryID: String
    public let url: URL
    /// 場所を指定していた設定ファイル
    public let configFile: URL
    /// そのツールのキャッシュであることを示す目印（どれか1つが直下にあればよい）。空なら確かめない
    public let markers: [String]
}

/// 設定ファイルの1項目の読み方
struct ToolConfigSource: Sendable {
    enum Format: Sendable {
        /// `key=value`（`.npmrc`、`pip.conf`）。section が nil なら最初のセクションより前だけを見る
        case ini(section: String?, keys: [String])
        /// `[table]` と `key = "value"`（`uv.toml`、`.bunfig.toml`）
        case toml(table: String?, key: String)
        /// トップレベルの `key: value`（`.yarnrc.yml`）
        case yaml(key: String)
        /// `key "value"`（Yarn classic の `.yarnrc`）
        case spaceSeparated(key: String)
        /// `KEY=VALUE`（`brew.env`、Go の `env`）
        case env(key: String)
        /// `<settings><localRepository>`（Maven の `settings.xml`）
        case mavenLocalRepository
    }

    let entryID: String
    /// ホームからの相対パス、または `/` で始まる絶対パス
    let file: String
    let format: Format
    /// 読んだ値から場所を作る（例: npm の `cache` → `<値>/_cacache`）
    var transform: @Sendable (URL) -> URL? = { $0 }
    var markers: [String] = []
}

public enum ToolConfig {
    static let sources: [ToolConfigSource] = [
        .init(entryID: "npm", file: ".npmrc", format: .ini(section: nil, keys: ["cache"]),
              transform: { $0.appending(path: "_cacache", directoryHint: .isDirectory) },
              markers: ["content-v2", "index-v5"]),
        .init(entryID: "pnpm", file: "Library/Preferences/pnpm/rc", format: .ini(section: nil, keys: ["store-dir"]),
              markers: ["v3", "v10", "v11"]),
        .init(entryID: "pnpm", file: ".npmrc", format: .ini(section: nil, keys: ["store-dir"]),
              markers: ["v3", "v10", "v11"]),
        .init(entryID: "yarn", file: ".yarnrc.yml", format: .yaml(key: "globalFolder"),
              transform: { $0.appending(path: "cache", directoryHint: .isDirectory) }),
        .init(entryID: "yarn", file: ".yarnrc", format: .spaceSeparated(key: "cache-folder")),
        .init(entryID: "bun", file: ".bunfig.toml", format: .toml(table: "install.cache", key: "dir")),
        .init(entryID: "bun", file: ".config/.bunfig.toml", format: .toml(table: "install.cache", key: "dir")),
        .init(entryID: "pip", file: "Library/Application Support/pip/pip.conf",
              format: .ini(section: "global", keys: ["cache-dir", "cache_dir"]), markers: ["http-v2", "http", "wheels"]),
        .init(entryID: "pip", file: ".config/pip/pip.conf",
              format: .ini(section: "global", keys: ["cache-dir", "cache_dir"]), markers: ["http-v2", "http", "wheels"]),
        .init(entryID: "pip", file: ".pip/pip.conf",
              format: .ini(section: "global", keys: ["cache-dir", "cache_dir"]), markers: ["http-v2", "http", "wheels"]),
        .init(entryID: "uv", file: ".config/uv/uv.toml", format: .toml(table: nil, key: "cache-dir"),
              markers: ["CACHEDIR.TAG"]),
        .init(entryID: "homebrew", file: ".homebrew/brew.env", format: .env(key: "HOMEBREW_CACHE"),
              markers: ["api", "downloads"]),
        .init(entryID: "homebrew", file: ".config/homebrew/brew.env", format: .env(key: "HOMEBREW_CACHE"),
              markers: ["api", "downloads"]),
        .init(entryID: "homebrew", file: "/etc/homebrew/brew.env", format: .env(key: "HOMEBREW_CACHE"),
              markers: ["api", "downloads"]),
        .init(entryID: "maven", file: ".m2/settings.xml", format: .mavenLocalRepository),
        .init(entryID: "go", file: "Library/Application Support/go/env", format: .env(key: "GOMODCACHE"),
              markers: ["cache"]),
        .init(entryID: "go", file: "Library/Application Support/go/env", format: .env(key: "GOPATH"),
              transform: { $0.appending(path: "pkg/mod", directoryHint: .isDirectory) }, markers: ["cache"]),
        .init(entryID: "go", file: "Library/Application Support/go/env", format: .env(key: "GOCACHE"),
              markers: ["trim.txt", "README"]),
    ]

    /// 設定ファイルで指定されたキャッシュの場所。存在するかどうかは確かめない
    /// - Parameter read: ファイルの中身を返す（読めなければ nil）。テストで差し替える
    public static func configuredLocations(
        home: URL,
        read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> [ConfiguredLocation] {
        var results: [ConfiguredLocation] = []
        for source in sources {
            let file = source.file.hasPrefix("/") ? URL(filePath: source.file) : home.appending(path: source.file)
            guard let contents = read(file),
                  let raw = value(in: contents, format: source.format),
                  let base = expandPath(raw, home: home, firstOfList: source.format.isGoPath),
                  let url = source.transform(base) else { continue }
            let location = ConfiguredLocation(entryID: source.entryID, url: url, configFile: file, markers: source.markers)
            if !results.contains(where: { $0.entryID == location.entryID && $0.url == location.url }) {
                results.append(location)
            }
        }
        return results
    }

    // MARK: - 値の展開

    /// `~`、`$HOME`、`${HOME}`、`${user.home}`、`${env.HOME}` を展開する。
    /// 絶対パスにならないもの、他の変数を含むもの、`..` を含むものは nil
    static func expandPath(_ raw: String, home: URL, firstOfList: Bool = false) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if firstOfList {
            value = String(value.split(separator: ":", omittingEmptySubsequences: true).first ?? "")
        }
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        if value == "~" {
            value = homePath
        } else if value.hasPrefix("~/") {
            value = homePath + value.dropFirst()
        }
        for variable in ["${HOME}", "${user.home}", "${env.HOME}", "$HOME"] {
            value = value.replacingOccurrences(of: variable, with: homePath)
        }
        guard value.hasPrefix("/"), !value.contains("$"), !value.contains("\0") else { return nil }
        let components = value.split(separator: "/")
        guard !components.contains(".."), !components.isEmpty else { return nil }
        return URL(filePath: "/" + components.filter { $0 != "." }.joined(separator: "/"), directoryHint: .isDirectory)
    }

    // MARK: - 形式ごとの読み方

    static func value(in contents: String, format: ToolConfigSource.Format) -> String? {
        switch format {
        case let .ini(section, keys): iniValue(contents, section: section, keys: keys)
        case let .toml(table, key): tomlValue(contents, table: table, key: key)
        case let .yaml(key): yamlValue(contents, key: key)
        case let .spaceSeparated(key): spaceSeparatedValue(contents, key: key)
        case let .env(key): envValue(contents, key: key)
        case .mavenLocalRepository: MavenSettingsParser.localRepository(in: contents)
        }
    }

    /// 後に書かれたものを優先する
    static func iniValue(_ contents: String, section: String?, keys: [String]) -> String? {
        var current: String?
        var found: String?
        for line in lines(contents, commentPrefixes: ["#", ";"]) {
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard current == section, let (key, value) = split(line, separator: "="), keys.contains(key) else { continue }
            found = unquote(value)
        }
        return found
    }

    static func tomlValue(_ contents: String, table: String?, key: String) -> String? {
        var current: String?
        var found: String?
        for line in lines(contents, commentPrefixes: ["#"]) {
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard current == table, let (name, value) = split(line, separator: "="), unquote(name) == key else { continue }
            found = unquote(stripTrailingComment(value))
        }
        return found
    }

    static func yamlValue(_ contents: String, key: String) -> String? {
        var found: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            // 字下げされた行は入れ子なので見ない
            guard let first = rawLine.first, !first.isWhitespace else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let (name, value) = split(line, separator: ":"), unquote(name) == key else { continue }
            found = unquote(stripTrailingComment(value))
        }
        return found
    }

    static func spaceSeparatedValue(_ contents: String, key: String) -> String? {
        var found: String?
        for line in lines(contents, commentPrefixes: ["#"]) {
            guard let space = line.firstIndex(where: \.isWhitespace),
                  unquote(String(line[..<space])) == key else { continue }
            found = unquote(String(line[space...]).trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    static func envValue(_ contents: String, key: String) -> String? {
        var found: String?
        for line in lines(contents, commentPrefixes: ["#"]) {
            let assignment = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            guard let (name, value) = split(assignment, separator: "="), name == key else { continue }
            found = unquote(value)
        }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func lines(_ contents: String, commentPrefixes: [String]) -> [String] {
        contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !commentPrefixes.contains { line.hasPrefix($0) } }
    }

    private static func split(_ line: String, separator: Character) -> (String, String)? {
        guard let index = line.firstIndex(of: separator) else { return nil }
        return (line[..<index].trimmingCharacters(in: .whitespaces),
                line[line.index(after: index)...].trimmingCharacters(in: .whitespaces))
    }

    /// 引用符の外の ` #` 以降を除く
    private static func stripTrailingComment(_ value: String) -> String {
        if value.hasPrefix("\"") || value.hasPrefix("'") { return value }
        guard let range = value.range(of: " #") else { return value }
        return value[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'" else { return value }
        guard let closing = value.dropFirst().firstIndex(of: first) else { return value }
        return String(value[value.index(after: value.startIndex)..<closing])
    }
}

extension ToolConfigSource.Format {
    var isGoPath: Bool {
        if case .env("GOPATH") = self { return true }
        return false
    }
}

/// `settings.xml` の `<settings><localRepository>`。コメントの中の例は読まない
private final class MavenSettingsParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var result: String?

    static func localRepository(in contents: String) -> String? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let delegate = MavenSettingsParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result.flatMap { $0.isEmpty ? nil : $0 }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path == ["settings", "localRepository"] {
            result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        path.removeLast()
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
