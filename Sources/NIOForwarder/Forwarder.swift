import NIOCore
import NIOPosix
import Logging

final class Forwarder: @unchecked Sendable {
    private let config: Config
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let trafficStatistics: TrafficStatistics
    private let statisticsReporter: StatisticsReporter
    private var tcpForwarders: [TCPForwarder] = []
    private var udpForwarders: [UDPForwarder] = []

    init(config: Config, logger: Logger) {
        self.config = config
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.trafficStatistics = TrafficStatistics(rules: config.rules)
        self.statisticsReporter = StatisticsReporter(
            statistics: trafficStatistics,
            config: config.statistics ?? StatisticsConfig(),
            logger: logger,
            eventLoop: eventLoopGroup.next()
        )
    }

    func start() -> EventLoopFuture<Void> {
        let futures: [EventLoopFuture<Void>] = config.rules.map { rule in
            let ruleStats = trafficStatistics.stats(for: rule.name)!
            switch rule.protocol {
            case .tcp:
                let forwarder = TCPForwarder(rule: rule, ruleStats: ruleStats, eventLoopGroup: eventLoopGroup, logger: logger)
                tcpForwarders.append(forwarder)
                return forwarder.start()
            case .udp:
                let forwarder = UDPForwarder(rule: rule, ruleStats: ruleStats, eventLoopGroup: eventLoopGroup, logger: logger)
                udpForwarders.append(forwarder)
                return forwarder.start()
            }
        }

        return EventLoopFuture.andAllComplete(futures, on: eventLoopGroup.next()).map {
            self.statisticsReporter.start()
        }
    }

    func stop() -> EventLoopFuture<Void> {
        statisticsReporter.shutdown()
        let futures = tcpForwarders.map { $0.stop() } + udpForwarders.map { $0.stop() }
        let promise = eventLoopGroup.next().makePromise(of: Void.self)

        EventLoopFuture.andAllComplete(futures, on: eventLoopGroup.next()).whenComplete { _ in
            self.eventLoopGroup.shutdownGracefully { _ in
                promise.succeed(())
            }
        }

        return promise.futureResult
    }
}
