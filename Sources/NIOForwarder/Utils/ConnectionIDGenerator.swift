import Atomics

/// Generates process-local, monotonically increasing, human-readable IDs.
///
/// Used for TCP connection IDs and UDP session IDs in log output.
enum ConnectionIDGenerator {
    private static let counter = ManagedAtomic<UInt64>(0)

    static func next() -> String {
        let value = counter.loadThenWrappingIncrement(ordering: .relaxed)
        return String(value, radix: 36, uppercase: false)
    }
}
