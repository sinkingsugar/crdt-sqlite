// Change.swift
// Represents a single change in the CRDT

import Foundation

/// Represents a single change in the CRDT system
///
/// This structure tracks all information needed for synchronization between nodes:
/// - What changed (record ID, column name, value)
/// - When it changed (version counters)
/// - Where it changed (node ID)
///
/// The Swift version is generic over the record ID type, allowing both Int64
/// (for traditional databases) and UUID (for distributed systems).
public struct Change<RecordID: CRDTRecordID>: Codable, Hashable {
    /// The record identifier
    public let recordId: RecordID

    /// Column name (nil indicates this is a record tombstone)
    public let columnName: String?

    /// New value (nil indicates column deletion, not the same as columnName being nil!)
    public let value: SQLiteValue?

    /// Per-column version counter (incremented on each edit to this column)
    public let columnVersion: UInt64

    /// Global logical clock at time of change creation
    public let dbVersion: UInt64

    /// Node that created this change
    public let nodeId: UInt64

    /// Local db_version when change was applied (for sync optimization)
    public let localDbVersion: UInt64

    /// Ephemeral flags (not persisted, used during processing)
    public var flags: UInt32

    // MARK: - Initializers

    public init(
        recordId: RecordID,
        columnName: String?,
        value: SQLiteValue?,
        columnVersion: UInt64,
        dbVersion: UInt64,
        nodeId: UInt64,
        localDbVersion: UInt64 = 0,
        flags: UInt32 = 0
    ) {
        self.recordId = recordId
        self.columnName = columnName
        self.value = value
        self.columnVersion = columnVersion
        self.dbVersion = dbVersion
        self.nodeId = nodeId
        self.localDbVersion = localDbVersion
        self.flags = flags
    }

    // MARK: - Computed Properties

    /// True if this change represents a record tombstone (entire record deleted)
    public var isTombstone: Bool {
        columnName == nil
    }

    /// True if this change represents a column deletion (column set to NULL)
    public var isColumnDeletion: Bool {
        columnName != nil && value == nil
    }

    /// True if this is a regular column update
    public var isColumnUpdate: Bool {
        columnName != nil && value != nil
    }
}

// MARK: - CustomStringConvertible

extension Change: CustomStringConvertible {
    public var description: String {
        if isTombstone {
            return "Change(recordId: \(recordId), TOMBSTONE, dbVersion: \(dbVersion), node: \(nodeId))"
        } else if isColumnDeletion {
            return "Change(recordId: \(recordId), column: \(columnName!), DELETE, dbVersion: \(dbVersion), node: \(nodeId))"
        } else {
            return "Change(recordId: \(recordId), column: \(columnName!), value: \(value!), dbVersion: \(dbVersion), node: \(nodeId))"
        }
    }
}

// MARK: - Conflict Resolution

extension Change {
    /// Determines if a remote change should be accepted over a local change
    /// using Last-Write-Wins (LWW) conflict resolution.
    ///
    /// Resolution order:
    /// 1. Column version (higher wins)
    /// 2. DB version (higher wins)
    /// 3. Node ID (higher wins)
    ///
    /// This matches the C++ implementation's three-way comparison.
    public static func shouldAcceptRemote(local: Change, remote: Change) -> Bool {
        // Compare column versions first
        if remote.columnVersion > local.columnVersion {
            return true
        } else if remote.columnVersion < local.columnVersion {
            return false
        }

        // Column versions equal, compare db versions
        if remote.dbVersion > local.dbVersion {
            return true
        } else if remote.dbVersion < local.dbVersion {
            return false
        }

        // Both versions equal, use node ID as tiebreaker
        return remote.nodeId > local.nodeId
    }
}

// MARK: - Convenience Type Aliases

/// Change with Int64 record IDs (for traditional databases)
public typealias Int64Change = Change<Int64>

/// Change with UUID record IDs (for distributed systems)
public typealias UUIDChange = Change<UUID>
