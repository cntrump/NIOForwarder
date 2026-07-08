import Foundation

struct Arguments {
    var configPath: String
    var logLevel: String?
}

struct ValidationError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func parseArguments(_ args: [String]) throws -> Arguments {
    var configPath: String?
    var logLevel: String?

    var index = 1
    while index < args.count {
        switch args[index] {
        case "--config", "-c":
            index += 1
            guard index < args.count else {
                throw ValidationError("Missing value for --config")
            }
            configPath = args[index]
        case "--log-level", "-l":
            index += 1
            guard index < args.count else {
                throw ValidationError("Missing value for --log-level")
            }
            logLevel = args[index]
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw ValidationError("Unknown argument: \(args[index])")
        }
        index += 1
    }

    guard let configPath = configPath else {
        throw ValidationError("--config is required")
    }

    return Arguments(configPath: configPath, logLevel: logLevel)
}

func printUsage() {
    print("""
    NIOForwarder - A TCP/UDP forwarding server powered by SwiftNIO.

    Usage:
      NIOForwarder --config <path> [--log-level <level>]

    Options:
      -c, --config <path>       Path to the JSON configuration file (required)
      -l, --log-level <level>  Override log level: trace, debug, info, notice, warning, error, critical
      -h, --help               Show this help message
    """)
}
