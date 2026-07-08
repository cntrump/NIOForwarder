import Foundation
import Logging

/// A stdout `LogHandler` that prefixes every line with an ISO8601 timestamp
/// with millisecond precision in UTC, similar to `StreamLogHandler` but with
/// a more diagnostic-friendly format.
///
/// Output format:
///     2026-07-08T12:34:56.789Z info NIOForwarder: rule=... conn=... [Source] message
struct FormattedLogHandler: LogHandler, @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private let dateFormatter: DateFormatter
    private let output: FileHandle

    var logLevel: Logger.Level = .info
    var metadataProvider: Logger.MetadataProvider?
    var metadata = Logger.Metadata() {
        didSet {
            self.prettyMetadata = prettify(self.metadata)
        }
    }

    private var prettyMetadata: String?

    init(label: String, output: FileHandle = .standardOutput) {
        self.label = label
        self.output = output

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        self.dateFormatter = formatter
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { self.metadata[metadataKey] }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    func log(event: LogEvent) {
        let effectiveMetadata = Self.prepareMetadata(
            base: self.metadata,
            provider: self.metadataProvider,
            explicit: event.metadata,
            error: event.error
        )

        let prettyMetadata: String?
        if let effectiveMetadata = effectiveMetadata {
            prettyMetadata = prettify(effectiveMetadata)
        } else {
            prettyMetadata = self.prettyMetadata
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        let timestamp = self.dateFormatter.string(from: Date())
        let line = "\(timestamp) \(event.level)\(self.label.isEmpty ? "" : " ")\(self.label):\(prettyMetadata.map { " \($0)" } ?? "") [\(event.source)] \(event.message)\n"

        self.output.write(line.data(using: .utf8) ?? Data())
    }

    @available(*, deprecated, renamed: "log(event:)")
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        self.log(
            event: LogEvent(
                level: level,
                message: message,
                metadata: metadata,
                source: source,
                file: file,
                function: function,
                line: line
            )
        )
    }

    private func prettify(_ metadata: Logger.Metadata) -> String? {
        guard !metadata.isEmpty else { return nil }
        return metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private static func prepareMetadata(
        base: Logger.Metadata,
        provider: Logger.MetadataProvider?,
        explicit: Logger.Metadata?,
        error: (any Error)?
    ) -> Logger.Metadata? {
        var metadata = base

        let provided = provider?.get() ?? [:]

        guard !provided.isEmpty || !((explicit ?? [:]).isEmpty) || error != nil else {
            return nil
        }

        if !provided.isEmpty {
            metadata.merge(provided, uniquingKeysWith: { _, provided in provided })
        }

        if let explicit = explicit, !explicit.isEmpty {
            metadata.merge(explicit, uniquingKeysWith: { _, explicit in explicit })
        }

        if let error {
            metadata["error.message"] = "\(error)"
            metadata["error.type"] = "\(String(reflecting: type(of: error)))"
        }

        return metadata
    }
}
