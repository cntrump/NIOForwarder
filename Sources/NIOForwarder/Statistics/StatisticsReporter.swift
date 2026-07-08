import Foundation
import Logging
import NIOCore

/// Periodically reports traffic statistics and optionally dumps them on shutdown.
final class StatisticsReporter: @unchecked Sendable {
    private let statistics: TrafficStatistics
    private let config: StatisticsConfig
    private let logger: Logger
    private let eventLoop: EventLoop
    private var scheduledTask: RepeatedTask?

    init(
        statistics: TrafficStatistics,
        config: StatisticsConfig,
        logger: Logger,
        eventLoop: EventLoop
    ) {
        self.statistics = statistics
        self.config = config
        self.logger = logger
        self.eventLoop = eventLoop
    }

    func start() {
        guard config.isEnabled else { return }
        let interval = TimeAmount.seconds(Int64(config.reportIntervalSeconds))
        scheduledTask = eventLoop.scheduleRepeatedTask(
            initialDelay: interval,
            delay: interval
        ) { [weak self] _ in
            self?.report(label: "periodic")
        }
    }

    func shutdown() {
        scheduledTask?.cancel()
        guard config.isEnabled, config.shouldLogOnShutdown else { return }
        report(label: "final")
    }

    private func report(label: String) {
        let snapshots = statistics.allSnapshots()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        for snapshot in snapshots {
            let counterName = Self.counterName(for: snapshot.protocolType)
            let sent = Self.formatBytes(snapshot.bytesSent)
            let received = Self.formatBytes(snapshot.bytesReceived)
            let total = snapshot.totalConnectionsOrSessions
            let active = snapshot.activeConnectionsOrSessions
            logger.info("[\(label)] Statistics: rule=\(snapshot.ruleName) protocol=\(snapshot.protocolType) sent=\(sent) received=\(received) total_\(counterName)=\(total) active_\(counterName)=\(active)")
        }

        if let outputPath = config.outputPath {
            do {
                let report = StatisticsReport(timestamp: timestamp, rules: snapshots)
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            } catch {
                logger.error("Failed to write statistics to '\(outputPath)': \(error)")
            }
        }
    }

    private static func counterName(for protocolType: ProtocolType) -> String {
        switch protocolType {
        case .tcp: return "connections"
        case .udp: return "sessions"
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let doubleBytes = Double(bytes)
        switch bytes {
        case 0: return "0B"
        case ..<1_024: return "\(bytes)B"
        case ..<(1_024 << 10): return String(format: "%.2fKB", doubleBytes / 1_024.0)
        case ..<(1_024 << 20): return String(format: "%.2fMB", doubleBytes / (1_024.0 * 1_024.0))
        default: return String(format: "%.2fGB", doubleBytes / (1_024.0 * 1_024.0 * 1_024.0))
        }
    }
}

private struct StatisticsReport: Codable {
    let timestamp: String
    let rules: [RuleStatsSnapshot]
}
