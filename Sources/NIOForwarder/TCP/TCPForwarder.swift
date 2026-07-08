import NIOCore
import NIOPosix
import Logging
import Atomics

final class TCPForwarder: @unchecked Sendable {
    private let rule: ForwardRule
    private let ruleStats: RuleStats
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private var serverChannel: Channel?

    init(rule: ForwardRule, ruleStats: RuleStats, eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.rule = rule
        self.ruleStats = ruleStats
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    func start() -> EventLoopFuture<Void> {
        let serverBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self = self else { return channel.eventLoop.makeSucceededVoidFuture() }
                return self.initializeClientChannel(channel)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let bindFuture = serverBootstrap.bind(host: rule.bindHost, port: rule.bindPort)

        bindFuture.whenSuccess { [weak self] channel in
            self?.serverChannel = channel
            self?.logger.info("TCP forwarder '\(self?.rule.name ?? "")' listening on \(channel.localAddress?.description ?? "unknown") -> \(self?.rule.targetHost ?? ""):\(self?.rule.targetPort ?? 0)")
        }

        bindFuture.whenFailure { [weak self] error in
            self?.logger.error("Failed to bind TCP forwarder '\(self?.rule.name ?? "")': \(error)")
        }

        return bindFuture.map { _ in () }
    }

    func stop() -> EventLoopFuture<Void> {
        guard let serverChannel = serverChannel else {
            return eventLoopGroup.next().makeSucceededVoidFuture()
        }
        return serverChannel.close()
    }

    private func initializeClientChannel(_ channel: Channel) -> EventLoopFuture<Void> {
        let clientHandler = TCPRelayHandler(direction: .clientToTarget, ruleStats: ruleStats, logger: logger)

        return channel.pipeline.addHandler(clientHandler).flatMap { [weak self] () -> EventLoopFuture<Channel> in
            guard let self = self else {
                channel.close(mode: .all, promise: nil)
                return channel.eventLoop.makeFailedFuture(TCPForwarderError.forwarderDeallocated)
            }
            let targetHandler = TCPRelayHandler(direction: .targetToClient, partner: channel, ruleStats: self.ruleStats, logger: self.logger)
            let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
                .channelInitializer { targetChannel in
                    targetChannel.pipeline.addHandler(targetHandler)
                }
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            return bootstrap.connect(host: self.rule.targetHost, port: self.rule.targetPort)
        }.map { targetChannel in
            clientHandler.setPartner(targetChannel)
            self.ruleStats.recordConnectionOpened()

            let closed = ManagedAtomic<Bool>(false)
            let onClose: @Sendable () -> Void = { [weak self] in
                let (exchanged, _) = closed.compareExchange(expected: false, desired: true, ordering: .relaxed)
                guard exchanged else { return }
                self?.ruleStats.recordConnectionClosed()
            }
            channel.closeFuture.whenComplete { _ in onClose() }
            targetChannel.closeFuture.whenComplete { _ in onClose() }

            self.logger.debug("TCP connection established for '\(self.rule.name)': \(channel.remoteAddress?.description ?? "unknown") -> \(self.rule.targetHost):\(self.rule.targetPort)")
        }.flatMapError { error in
            self.logger.warning("Failed to connect target for '\(self.rule.name)': \(error)")
            channel.close(mode: .all, promise: nil)
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}

enum TCPForwarderError: Error {
    case forwarderDeallocated
}
