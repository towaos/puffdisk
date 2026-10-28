import Foundation
import PuffdiskCore

/// M1: アプリと同じ手順で候補一覧を出す（DESIGN.md 13 の「自分の Mac で妥当なキャッシュ一覧が出る」の確認用）
enum ScanCommand {
    static func run() {
        let scanner = Scanner(home: home)
        let (plan, planTime) = measure { scanner.plan() }
        print("== 単位 \(plan.units.count) 件（\(planTime.milliseconds)）")

        var candidates: [Candidate] = []
        let (_, measureTime) = measure {
            for unit in plan.units {
                let stats = Scanner.measure(unit)
                if let candidate = RuleEngine.candidate(for: unit, stats: stats, settings: scanner.settings, home: home) {
                    candidates.append(candidate)
                }
            }
        }
        print("== 候補 \(candidates.count) 件（測定 \(measureTime.milliseconds)）")
        for category in [CandidateCategory.cache, .review] {
            let inCategory = candidates.filter { $0.category == category }
            let total = inCategory.reduce(0) { $0 + $1.reclaimableBytes }
            print("\n[\(category == .cache ? "キャッシュ" : "要確認")] \(formatBytes(total))")
            for candidate in inCategory.sorted(by: { ($0.group, -$0.reclaimableBytes) < ($1.group, -$1.reclaimableBytes) }) {
                print("\(candidate.defaultSelected ? "☑" : "☐") [\(candidate.group)] \(candidate.title)  \(formatBytes(candidate.reclaimableBytes))  \(candidate.detail)")
                for reason in candidate.reasons {
                    print("     \(reason.text)")
                }
            }
        }

        if !plan.skipped.isEmpty {
            print("\n== 走査しなかった場所")
            for skipped in plan.skipped {
                print("- \(skipped.entryID): \(RuleEngine.displayPath(skipped.url, home: home))  \(skipped.reason.description)")
            }
        }
    }
}
