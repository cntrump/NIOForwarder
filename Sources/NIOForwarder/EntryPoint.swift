import Foundation
import Logging
import NIOPosix
import Darwin

@main
enum EntryPoint {
    static func main() async {
        do {
            let args = try parseArguments(ProcessInfo.processInfo.arguments)
            let config = try Config.load(from: args.configPath)

            let level = Logger.Level(configValue: args.logLevel ?? config.logLevel) ?? .info
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardOutput(label: label)
                handler.logLevel = level
                return handler
            }
            let logger = Logger(label: "NIOForwarder")

            let forwarder = Forwarder(config: config, logger: logger)

            let runningTask = Task {
                try await forwarder.start().get()
                logger.info("NIOForwarder started.")
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
                throw CancellationError()
            }

            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.main)
            signalSource.setEventHandler {
                runningTask.cancel()
            }
            signal(SIGINT, SIG_IGN)
            signalSource.resume()

            do {
                try await runningTask.value
            } catch is CancellationError {
                logger.info("Shutting down...")
                try? await forwarder.stop().get()
                logger.info("NIOForwarder stopped.")
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            printUsage()
            exit(1)
        }
    }
}
