import NIOCore
import NIOPosix
import Logging
import Foundation
import Atomics

final class UDPForwarder: @unchecked Sendable {
    private let rule: ForwardRule
    private let ruleStats: RuleStats
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private let sessionTimeoutSeconds: Int
    private let isShuttingDown = ManagedAtomic<Bool>(false)
    private var serverChannel: Channel?
    private var cleanupTask: RepeatedTask?
    private var sessions: [SocketAddress: UDPSession] = [:]

    init(rule: ForwardRule, ruleStats: RuleStats, eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.rule = rule
        self.ruleStats = ruleStats
        self.eventLoopGroup = eventLoopGroup
        var logger = logger
        logger[metadataKey: "rule"] = "\(rule.name)"
        self.logger = logger
        self.sessionTimeoutSeconds = rule.udpSessionTimeoutSeconds ?? 60
    }

    func start() -> EventLoopFuture<Void> {
        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self = self else { return channel.eventLoop.makeSucceededVoidFuture() }
                return channel.pipeline.addHandler(UDPInboundHandler(forwarder: self))
            }

        let bindFuture = bootstrap.bind(host: rule.bindHost, port: rule.bindPort)

        bindFuture.whenSuccess { [weak self] channel in
            guard let self = self else { return }
            self.serverChannel = channel
            self.scheduleCleanup()
            self.logger.info("UDP forwarder '\(self.rule.name)' listening on \(channel.localAddress?.description ?? "unknown") -> \(self.rule.targetHost):\(self.rule.targetPort)")
        }

        bindFuture.whenFailure { [weak self] error in
            self?.logger.error("Failed to bind UDP forwarder '\(self?.rule.name ?? "")': \(error)")
        }

        return bindFuture.map { _ in () }
    }

    func stop() -> EventLoopFuture<Void> {
        isShuttingDown.store(true, ordering: .relaxed)
        cleanupTask?.cancel()
        guard let serverChannel = serverChannel else {
            return eventLoopGroup.next().makeSucceededVoidFuture()
        }
        return serverChannel.close()
    }

    func relay(data: ByteBuffer, from clientAddress: SocketAddress) {
        guard let serverChannel = serverChannel else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let bytes = data.readableBytes

        ruleStats.recordSent(bytes)

        if let session = sessions[clientAddress] {
            logger.trace("client->target \(bytes) bytes, session=\(session.sessionID)")
            session.targetChannel.writeAndFlush(data, promise: nil)
            sessions[clientAddress]?.lastActivity = now
            return
        }


        let clientBootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        clientBootstrap.connect(host: rule.targetHost, port: rule.targetPort).whenSuccess { [weak self] targetChannel in
            guard let self = self else {
                targetChannel.close(mode: .all, promise: nil)
                return
            }

            // Ensure session mutations happen on the server channel's event loop.
            self.serverChannel?.eventLoop.execute {
                let sessionID = ConnectionIDGenerator.next()
                let session = UDPSession(
                    sessionID: sessionID,
                    targetChannel: targetChannel,
                    lastActivity: now
                )
                self.sessions[clientAddress] = session
                self.ruleStats.recordConnectionOpened()

                let handler = SessionTargetHandler(
                    sessionID: sessionID,
                    ruleName: self.rule.name,
                    clientAddress: clientAddress,
                    serverChannel: serverChannel,
                    ruleStats: self.ruleStats,
                    onActivity: { [weak self] in
                        guard let forwarder = self, let eventLoop = forwarder.serverChannel?.eventLoop else { return }
                        let now = DispatchTime.now().uptimeNanoseconds
                        eventLoop.execute { [weak self] in
                            self?.sessions[clientAddress]?.lastActivity = now
                        }
                    },
                    onClose: { [weak self] in
                        guard let forwarder = self,
                              !forwarder.isShuttingDown.load(ordering: .relaxed),
                              let serverChannel = forwarder.serverChannel,
                              serverChannel.isActive else { return }
                        serverChannel.eventLoop.execute { [weak self] in
                            guard let forwarder = self else { return }
                            if forwarder.sessions.removeValue(forKey: clientAddress) != nil {
                                forwarder.ruleStats.recordConnectionClosed()
                            }
                        }
                    },
                    logger: self.logger
                )

                targetChannel.pipeline.addHandler(handler).whenSuccess { _ in
                    targetChannel.writeAndFlush(data, promise: nil)
                    self.logger.debug("UDP session created: \(clientAddress) -> \(self.rule.targetHost):\(self.rule.targetPort), session=\(sessionID)")
                    self.logger.trace("client->target \(bytes) bytes, session=\(sessionID)")
                }
            }
        }
    }

    private func scheduleCleanup() {
        guard let eventLoop = serverChannel?.eventLoop else { return }
        cleanupTask = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(5),
            delay: .seconds(5)
        ) { [weak self] _ in
            self?.expireSessions()
        }
    }

    private func expireSessions() {
        let now = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(sessionTimeoutSeconds) * 1_000_000_000

        var expiredKeys: [SocketAddress] = []
        for (key, session) in sessions {
            if now - session.lastActivity >= timeoutNanos {
                expiredKeys.append(key)
                session.targetChannel.close(mode: .all, promise: nil)
            }
        }

        for key in expiredKeys {
            if sessions.removeValue(forKey: key) != nil {
                ruleStats.recordConnectionClosed()
            }
        }

        if !expiredKeys.isEmpty {
            logger.debug("Expired \(expiredKeys.count) UDP session(s) for '\(rule.name)'")
        }
    }
}

final class UDPInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private weak var forwarder: UDPForwarder?

    init(forwarder: UDPForwarder) {
        self.forwarder = forwarder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        forwarder?.relay(data: envelope.data, from: envelope.remoteAddress)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
    }
}
