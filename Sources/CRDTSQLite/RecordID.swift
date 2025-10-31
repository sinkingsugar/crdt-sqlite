// RecordID.swift
// Record ID protocol and implementations

import Foundation

/// Protocol for record identifiers used in CRDT synchronization
///
/// Record IDs must be hashable and codable for efficient storage and transmission.
/// Two implementations are provided:
/// - Int64: For single-node or primary-replica setups (uses SQLite AUTO-INCREMENT)
/// - UUID: For distributed systems (eliminates coordination overhead)
public protocol CRDTRecordID: Hashable, Codable {
    /// Generate a new unique record ID
    static func generate() -> Self

    /// Generate a new unique record ID incorporating a node ID
    /// This can help avoid collisions in distributed systems
    static func generate(withNode nodeId: UInt64) -> Self
}

// MARK: - Int64 Implementation

extension Int64: CRDTRecordID {
    /// Generate a new Int64 ID (returns 0, actual ID assigned by SQLite AUTO-INCREMENT)
    public static func generate() -> Int64 {
        return 0
    }

    /// Generate a new Int64 ID incorporating node ID (not typically used)
    public static func generate(withNode nodeId: UInt64) -> Int64 {
        return 0
    }
}

// MARK: - UUID Implementation

extension UUID: CRDTRecordID {
    /// Generate a new random UUID
    public static func generate() -> UUID {
        return UUID()
    }

    /// Generate a new UUID incorporating node ID in the timestamp field
    /// This reduces collision probability by partitioning the ID space
    public static func generate(withNode nodeId: UInt64) -> UUID {
        // Use node ID as part of the UUID to partition the space
        // This is a simple approach - production code might want a more sophisticated scheme
        var bytes = UUID().uuid

        // Embed node ID in the first 8 bytes
        withUnsafeBytes(of: nodeId.bigEndian) { nodeBytes in
            for i in 0..<8 {
                bytes.0 = nodeBytes[i]
            }
        }

        return UUID(uuid: bytes)
    }
}

// MARK: - Helper Extensions

extension UUID {
    /// Convert UUID to Data for SQLite BLOB storage
    public var data: Data {
        return withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Create UUID from Data (from SQLite BLOB)
    public init?(data: Data) {
        guard data.count == 16 else { return nil }

        self = data.withUnsafeBytes { buffer in
            UUID(uuid: buffer.load(as: uuid_t.self))
        }
    }
}
