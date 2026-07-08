import Foundation
import Logging

struct Config: Codable {
    var logLevel: String?
    var statistics: StatisticsConfig?
    var rules: [ForwardRule]
}

struct StatisticsConfig: Codable {
    var enabled: Bool?
    var intervalSeconds: Int?
    var outputPath: String?
    var logOnShutdown: Bool?
}

struct ForwardRule: Codable {
    var name: String
    var `protocol`: ProtocolType
    var bindHost: String
    var bindPort: Int
    var targetHost: String
    var targetPort: Int
    var udpSessionTimeoutSeconds: Int?
}

enum ProtocolType: String, Codable {
    case tcp
    case udp
}

extension StatisticsConfig {
    var isEnabled: Bool { enabled ?? true }
    var reportIntervalSeconds: Int { intervalSeconds ?? 60 }
    var shouldLogOnShutdown: Bool { logOnShutdown ?? true }
}

extension Config {
    static func load(from path: String) throws -> Config {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Config.self, from: data)
    }
}

extension Logging.Logger.Level {
    init?(configValue: String?) {
        guard let value = configValue?.lowercased() else { return nil }
        switch value {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "notice": self = .notice
        case "warning", "warn": self = .warning
        case "error": self = .error
        case "critical": self = .critical
        default: return nil
        }
    }
}
