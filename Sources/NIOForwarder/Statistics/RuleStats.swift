import Atomics
import Foundation

/// Per-rule traffic counters. All operations are lock-free so they can be
/// called from any event loop without blocking the forwarding path.
final class RuleStats: @unchecked Sendable {
    let ruleName: String
    let protocolType: ProtocolType

    private let bytesSent: ManagedAtomic<UInt64>
    private let bytesReceived: ManagedAtomic<UInt64>
    private let totalConnectionsOrSessions: ManagedAtomic<UInt64>
    private let activeConnectionsOrSessions: ManagedAtomic<Int>

    init(ruleName: String, protocolType: ProtocolType) {
        self.ruleName = ruleName
        self.protocolType = protocolType
        self.bytesSent = ManagedAtomic(0)
        self.bytesReceived = ManagedAtomic(0)
        self.totalConnectionsOrSessions = ManagedAtomic(0)
        self.activeConnectionsOrSessions = ManagedAtomic(0)
    }

    func recordSent(_ count: Int) {
        guard count > 0 else { return }
        bytesSent.wrappingIncrement(by: UInt64(count), ordering: .relaxed)
    }

    func recordReceived(_ count: Int) {
        guard count > 0 else { return }
        bytesReceived.wrappingIncrement(by: UInt64(count), ordering: .relaxed)
    }

    func recordConnectionOpened() {
        totalConnectionsOrSessions.wrappingIncrement(ordering: .relaxed)
        activeConnectionsOrSessions.wrappingIncrement(ordering: .relaxed)
    }

    func recordConnectionClosed() {
        while true {
            let current = activeConnectionsOrSessions.load(ordering: .relaxed)
            guard current > 0 else { return }
            let (exchanged, _) = activeConnectionsOrSessions.compareExchange(
                expected: current,
                desired: current - 1,
                ordering: .relaxed
            )
            if exchanged { return }
        }
    }

    func snapshot() -> RuleStatsSnapshot {
        RuleStatsSnapshot(
            ruleName: ruleName,
            protocolType: protocolType,
            bytesSent: bytesSent.load(ordering: .relaxed),
            bytesReceived: bytesReceived.load(ordering: .relaxed),
            totalConnectionsOrSessions: totalConnectionsOrSessions.load(ordering: .relaxed),
            activeConnectionsOrSessions: activeConnectionsOrSessions.load(ordering: .relaxed)
        )
    }
}

struct RuleStatsSnapshot: Codable {
    let ruleName: String
    let protocolType: ProtocolType
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let totalConnectionsOrSessions: UInt64
    let activeConnectionsOrSessions: Int
}
