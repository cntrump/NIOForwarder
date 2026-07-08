import NIOCore
import Logging

/// Relays all inbound bytes to a partner channel.
final class TCPRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    enum Direction: String {
        case clientToTarget = "client→target"
        case targetToClient = "target→client"
    }

    private let direction: Direction
    private let connectionID: String
    private var partner: Channel?
    private let ruleStats: RuleStats
    private let logger: Logger

    init(
        direction: Direction,
        connectionID: String,
        partner: Channel? = nil,
        ruleStats: RuleStats,
        logger: Logger
    ) {
        self.direction = direction
        self.connectionID = connectionID
        self.partner = partner
        self.ruleStats = ruleStats
        var logger = logger
        logger[metadataKey: "conn"] = "\(connectionID)"
        logger[metadataKey: "direction"] = "\(direction.rawValue)"
        self.logger = logger
    }

    func setPartner(_ channel: Channel) {
        self.partner = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let bytes = buffer.readableBytes
        logger.trace("Read \(bytes) bytes")

        guard let partner = partner else {
            logger.warning("Dropping \(bytes) bytes, no partner")
            return
        }
        if partner.isActive {
            switch direction {
            case .clientToTarget:
                ruleStats.recordSent(bytes)
            case .targetToClient:
                ruleStats.recordReceived(bytes)
            }
            partner.writeAndFlush(buffer, promise: nil)
            logger.trace("Relayed \(bytes) bytes")
        } else {
            logger.debug("Partner not active, dropping \(bytes) bytes")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Channel inactive")
        if let partner = partner, partner.isActive {
            partner.close(mode: .all, promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let remoteAddress = context.channel.remoteAddress?.description ?? "unknown"
        logger.warning("Channel error (remote: \(remoteAddress)): \(error)")
        if let partner = partner, partner.isActive {
            partner.close(mode: .all, promise: nil)
        }
        context.close(mode: .all, promise: nil)
    }
}
