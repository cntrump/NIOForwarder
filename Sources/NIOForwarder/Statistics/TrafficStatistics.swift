import NIOConcurrencyHelpers

/// Owns all per-rule statistics objects. The registry is only mutated/read
/// during setup and reporting, never on the hot forwarding path.
final class TrafficStatistics: Sendable {
    private let statsByRule: NIOLockedValueBox<[String: RuleStats]>

    init(rules: [ForwardRule]) {
        var map: [String: RuleStats] = [:]
        for rule in rules {
            map[rule.name] = RuleStats(ruleName: rule.name, protocolType: rule.protocol)
        }
        self.statsByRule = NIOLockedValueBox(map)
    }

    func stats(for ruleName: String) -> RuleStats? {
        statsByRule.withLockedValue { $0[ruleName] }
    }

    func allSnapshots() -> [RuleStatsSnapshot] {
        statsByRule.withLockedValue { stats in
            stats.values.map { $0.snapshot() }.sorted { $0.ruleName < $1.ruleName }
        }
    }
}
