import NIOCore
import NIOPosix

struct UDPSession {
    let targetChannel: Channel
    var lastActivity: UInt64
}

final class SessionTargetHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let clientAddress: SocketAddress
    private weak var serverChannel: Channel?
    private let ruleStats: RuleStats
    private let onActivity: () -> Void
    private let onClose: () -> Void

    init(
        clientAddress: SocketAddress,
        serverChannel: Channel,
        ruleStats: RuleStats,
        onActivity: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.clientAddress = clientAddress
        self.serverChannel = serverChannel
        self.ruleStats = ruleStats
        self.onActivity = onActivity
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        onActivity()
        ruleStats.recordReceived(envelope.data.readableBytes)
        guard let serverChannel = serverChannel else {
            return
        }
        let reply = AddressedEnvelope<ByteBuffer>(remoteAddress: clientAddress, data: envelope.data)
        serverChannel.writeAndFlush(reply, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(mode: .all, promise: nil)
    }
}
