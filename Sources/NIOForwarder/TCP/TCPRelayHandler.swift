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
    private var partner: Channel?
    private let ruleStats: RuleStats
    private let logger: Logger

    init(direction: Direction, partner: Channel? = nil, ruleStats: RuleStats, logger: Logger) {
        self.direction = direction
        self.partner = partner
        self.ruleStats = ruleStats
        self.logger = logger
    }

    func setPartner(_ channel: Channel) {
        self.partner = channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let partner = partner else {
            logger.warning("(\(direction.rawValue)) Dropping \(buffer.readableBytes) bytes, no partner")
            return
        }
        if partner.isActive {
            switch direction {
            case .clientToTarget:
                ruleStats.recordSent(buffer.readableBytes)
            case .targetToClient:
                ruleStats.recordReceived(buffer.readableBytes)
            }
            partner.writeAndFlush(buffer, promise: nil)
        } else {
            logger.debug("(\(direction.rawValue)) Partner not active, dropping data")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("(\(direction.rawValue)) Channel inactive")
        if let partner = partner, partner.isActive {
            partner.close(mode: .all, promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("(\(direction.rawValue)) Error: \(error)")
        if let partner = partner, partner.isActive {
            partner.close(mode: .all, promise: nil)
        }
        context.close(mode: .all, promise: nil)
    }
}
