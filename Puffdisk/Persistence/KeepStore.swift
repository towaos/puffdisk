import Foundation
import SwiftData

/// 「残す」にしたもの（DESIGN.md 6.1・10.2）。以後候補にしない
@Model
final class KeepRule {
    enum Reason: String, Codable {
        /// 本人が指定した
        case user
        /// 復元した（M3）
        case restored
    }

    /// `Candidate.id`（パス。複数の場所をまとめた単位は改行でつなぐ）
    @Attribute(.unique) var path: String
    /// 一覧に出していたときの名前
    var title: String
    var addedAt: Date
    var reasonRawValue: String

    var reason: Reason { Reason(rawValue: reasonRawValue) ?? .user }

    init(path: String, title: String, reason: Reason, addedAt: Date = Date()) {
        self.path = path
        self.title = title
        self.addedAt = addedAt
        reasonRawValue = reason.rawValue
    }
}

@MainActor
final class KeepStore {
    private let persistence: Persistence

    init(persistence: Persistence) {
        self.persistence = persistence
    }

    func all() -> [KeepRule] {
        (try? persistence.context.fetch(FetchDescriptor<KeepRule>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))) ?? []
    }

    func add(path: String, title: String, reason: KeepRule.Reason = .user) {
        guard !all().contains(where: { $0.path == path }) else { return }
        persistence.context.insert(KeepRule(path: path, title: title, reason: reason))
        persistence.save()
    }

    func remove(path: String) {
        for rule in all() where rule.path == path {
            persistence.context.delete(rule)
        }
        persistence.save()
    }
}
