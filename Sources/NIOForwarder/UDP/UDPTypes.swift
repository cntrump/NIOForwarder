import NIOCore
import NIOPosix
import Logging

struct UDPSession {
    let sessionID: String
    let targetChannel: Channel
    var lastActivity: UInt64
}

final class SessionTargetHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let sessionID: String
    private let clientAddress: SocketAddress
    private weak var serverChannel: Channel?
    private let ruleStats: RuleStats
    private let onActivity: () -> Void
    private let onClose: () -> Void
    private let logger: Logger

    init(
        sessionID: String,
        ruleName: String,
        clientAddress: SocketAddress,
        serverChannel: Channel,
        ruleStats: RuleStats,
        onActivity: @escaping () -> Void,
        onClose: @escaping () -> Void,
        logger: Logger
    ) {
        self.sessionID = sessionID
        self.clientAddress = clientAddress
        self.serverChannel = serverChannel
        self.ruleStats = ruleStats
        self.onActivity = onActivity
        self.onClose = onClose
        var logger = logger
        logger[metadataKey: "rule"] = "\(ruleName)"
        logger[metadataKey: "session"] = "\(sessionID)"
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let bytes = envelope.data.readableBytes
        onActivity()
        ruleStats.recordReceived(bytes)
        logger.trace("target->client \(bytes) bytes")
        guard let serverChannel = serverChannel else {
            return
        }
        let reply = AddressedEnvelope<ByteBuffer>(remoteAddress: clientAddress, data: envelope.data)
        serverChannel.writeAndFlush(reply, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Session target channel inactive")
        onClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Session error: \(error)")
        context.close(mode: .all, promise: nil)
    }
}
