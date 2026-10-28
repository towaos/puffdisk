import Foundation
import Testing
@testable import PuffdiskCore

struct ToolConfigTests {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    func locations(_ files: [String: String]) -> [String: [String]] {
        let found = ToolConfig.configuredLocations(home: home) { url in files[url.path(percentEncoded: false)] }
        return Dictionary(grouping: found, by: \.entryID).mapValues { $0.map { $0.url.path(percentEncoded: false) } }
    }

    @Test func npmCacheGetsCacacheAppended() {
        let result = locations(["/Users/someone/.npmrc": "registry=https://example.com/\ncache=~/npm-cache\n"])
        #expect(result["npm"] == ["/Users/someone/npm-cache/_cacache/"])
    }

    @Test func iniIgnoresOtherSectionsAndComments() {
        let npmrc = "; cache=/commented\n# cache=/also\n[other]\ncache=/in-section\n"
        #expect(locations(["/Users/someone/.npmrc": npmrc])["npm"] == nil)
        let pip = "[install]\ncache-dir=/wrong\n[global]\ncache-dir = /Users/someone/.pipcache\n"
        #expect(locations(["/Users/someone/.config/pip/pip.conf": pip])["pip"] == ["/Users/someone/.pipcache/"])
    }

    @Test func pnpmStoreDirFromEitherFile() {
        let result = locations([
            "/Users/someone/Library/Preferences/pnpm/rc": "store-dir=${HOME}/.pnpm-store",
            "/Users/someone/.npmrc": "store-dir=/Users/someone/old-store",
        ])
        #expect(result["pnpm"] == ["/Users/someone/.pnpm-store/", "/Users/someone/old-store/"])
    }

    @Test func tomlTablesAndKeys() {
        let bunfig = "[install]\nregistry = \"x\"\n\n[install.cache]\ndir = \"~/.bun-cache\" # コメント\n"
        let uv = "cache-dir = \"/Users/someone/.uvc\"\n[pip]\ncache-dir = \"/wrong\"\n"
        let result = locations([
            "/Users/someone/.bunfig.toml": bunfig,
            "/Users/someone/.config/uv/uv.toml": uv,
        ])
        #expect(result["bun"] == ["/Users/someone/.bun-cache/"])
        #expect(result["uv"] == ["/Users/someone/.uvc/"])
    }

    @Test func yarnBerryAndClassic() {
        let berry = "nodeLinker: node-modules\npackageExtensions:\n  globalFolder: /nested\nglobalFolder: '~/.yarn-global'\n"
        let result = locations([
            "/Users/someone/.yarnrc.yml": berry,
            "/Users/someone/.yarnrc": "# comment\ncache-folder \"/Users/someone/.yarn-classic\"\n",
        ])
        #expect(result["yarn"] == ["/Users/someone/.yarn-global/cache/", "/Users/someone/.yarn-classic/"])
    }

    @Test func homebrewEnv() {
        let result = locations(["/Users/someone/.homebrew/brew.env": "export HOMEBREW_CACHE=\"$HOME/brew-cache\"\n"])
        #expect(result["homebrew"] == ["/Users/someone/brew-cache/"])
    }

    @Test func mavenIgnoresCommentedExample() {
        let commented = """
        <settings>
          <!-- localRepository
           | Default: ${user.home}/.m2/repository
          <localRepository>/path/to/local/repo</localRepository>
          -->
        </settings>
        """
        #expect(locations(["/Users/someone/.m2/settings.xml": commented])["maven"] == nil)
        let real = "<settings><localRepository>${user.home}/m2repo</localRepository></settings>"
        #expect(locations(["/Users/someone/.m2/settings.xml": real])["maven"] == ["/Users/someone/m2repo/"])
    }

    @Test func goEnvUsesModCacheGoPathAndBuildCache() {
        let env = "GOPATH=/Users/someone/.go:/Users/someone/other\nGOCACHE=/Users/someone/.gocache\n"
        let result = locations(["/Users/someone/Library/Application Support/go/env": env])
        #expect(result["go"] == ["/Users/someone/.go/pkg/mod/", "/Users/someone/.gocache/"])

        let withModCache = "GOMODCACHE=/Users/someone/mods\nGOPATH=/Users/someone/.go\n"
        #expect(locations(["/Users/someone/Library/Application Support/go/env": withModCache])["go"]
            == ["/Users/someone/mods/", "/Users/someone/.go/pkg/mod/"])
    }

    @Test(arguments: ["relative/path", "$XDG_CACHE_HOME/npm", "/Users/someone/../other", "", "~user/x"])
    func rejectsUnresolvablePaths(raw: String) {
        #expect(ToolConfig.expandPath(raw, home: home) == nil)
    }

    @Test func expandsHomeForms() {
        for raw in ["~/a", "$HOME/a", "${HOME}/a", "${user.home}/a", "${env.HOME}/a", "/Users/someone/./a/"] {
            #expect(ToolConfig.expandPath(raw, home: home)?.path(percentEncoded: false) == "/Users/someone/a/", "\(raw)")
        }
    }
}
