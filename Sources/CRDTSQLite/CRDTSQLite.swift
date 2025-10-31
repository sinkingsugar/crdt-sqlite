// CRDTSQLite.swift
// Main CRDT-enabled SQLite wrapper

import Foundation
import SQLite3

// MARK: - Constants and Types

internal enum CRDTConstants {
    static let maxTableNameLength = 23
    static let maxExcludedNodes = 100
}

internal enum OperationType: Int32 {
    case insert = 18  // SQLITE_INSERT
    case update = 23  // SQLITE_UPDATE
    case delete = 9   // SQLITE_DELETE
}

/// CRDT-enabled SQLite database wrapper
///
/// This class wraps a SQLite database and enables CRDT synchronization
/// for specified tables. Changes are tracked automatically using SQLite's
/// triggers and WAL hooks, and can be synchronized with other nodes.
///
/// **Thread Safety:**
/// ⚠️  This class is NOT thread-safe. Do not access the same CRDTSQLite instance
/// from multiple threads concurrently. Use one instance per thread or protect
/// access with external synchronization.
///
/// **Example Usage:**
/// ```swift
/// let db = try CRDTSQLite(path: "myapp.db", nodeId: 1)
/// try db.enableCRDT(for: "users")
///
/// // Use normal SQL
/// try db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'a@x.com')")
///
/// // Sync with other nodes
/// let changes = try db.getChangesSince(0)
/// // ... send to other nodes ...
///
/// // Merge remote changes
/// let accepted = try db.mergeChanges(remoteChanges)
/// ```
public final class CRDTSQLite<RecordID: CRDTRecordID>: CRDTCallbackHandler {
    // MARK: - Properties

    internal let db: OpaquePointer
    internal let nodeId: UInt64
    internal var trackedTable: String?
    internal var columnTypes: [String: Int32] = [:]
    internal var pendingSchemaRefresh = false
    internal var processingWalChanges = false
    internal var clockOverflow = false
    private var callbackBox: Unmanaged<CallbackBox>?

    // MARK: - Initialization

    /// Creates a CRDT-enabled SQLite database
    ///
    /// - Parameters:
    ///   - path: Path to the SQLite database file
    ///   - nodeId: Unique identifier for this node (must be unique across all nodes)
    /// - Throws: `CRDTError` if database cannot be opened
    public init(path: String, nodeId: UInt64) throws {
        self.nodeId = nodeId

        // Open database with full mutex for thread safety
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)

        guard result == SQLITE_OK, let db = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let db = db {
                sqlite3_close(db)
            }
            throw CRDTError.databaseOpenFailed(path: path, message: message)
        }

        self.db = db

        // Enable foreign keys
        try executeSQLOrThrow(db, "PRAGMA foreign_keys = ON")

        // Enable WAL mode for better concurrency
        try executeSQLOrThrow(db, "PRAGMA journal_mode=WAL")

        // Install hooks using callback bridge
        let box = CallbackBox(handler: self)
        let unmanagedBox = Unmanaged.passRetained(box)
        self.callbackBox = unmanagedBox
        let context = unmanagedBox.toOpaque()

        sqlite3_set_authorizer(db, crdtAuthorizerCallback, context)
        sqlite3_wal_hook(db, crdtWalCallback, context)
        sqlite3_rollback_hook(db, crdtRollbackCallback, context)
    }

    deinit {
        // Clean up callback box
        if let box = callbackBox {
            box.release()
        }
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Enables CRDT synchronization for a table
    ///
    /// Creates shadow tables to track column versions and tombstones.
    /// After calling this, all modifications to the table will be tracked.
    ///
    /// - Parameter tableName: Name of the table to enable CRDT for (max 23 chars)
    /// - Throws: `CRDTError` if table doesn't exist or shadow tables cannot be created
    public func enableCRDT(for tableName: String) throws {
        guard trackedTable == nil else {
            throw CRDTError.internalError("CRDT already enabled for table: \(trackedTable!)")
        }

        // Validate table name
        guard tableName.isValidTableName else {
            throw CRDTError.tableNameInvalid(tableName)
        }

        guard tableName.count <= CRDTConstants.maxTableNameLength else {
            throw CRDTError.tableNameTooLong(tableName, maxLength: CRDTConstants.maxTableNameLength)
        }

        // Check if table exists
        let stmt = try prepareSQLOrThrow(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?")
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw CRDTError.internalError("Table does not exist: \(tableName)")
        }

        // Cache column types and create shadow tables
        try cacheColumnTypes(tableName: tableName)
        try createShadowTables(tableName: tableName)

        // Set tracked table last (after everything is ready)
        trackedTable = tableName
    }

    /// Executes SQL statement(s)
    ///
    /// Changes to CRDT-enabled tables are tracked automatically.
    ///
    /// - Parameter sql: SQL statement(s) to execute
    /// - Throws: `CRDTError` if execution fails
    public func execute(_ sql: String) throws {
        try executeSQLOrThrow(db, sql)

        // Handle schema refresh if ALTER TABLE was detected
        if pendingSchemaRefresh {
            try refreshSchema()
            pendingSchemaRefresh = false
        }
    }

    /// Prepares a SQL statement
    ///
    /// Use this for parameterized queries. Changes to CRDT-enabled tables
    /// are tracked automatically when the statement is executed.
    ///
    /// - Parameter sql: SQL statement to prepare
    /// - Returns: Prepared statement (caller must call sqlite3_finalize)
    /// - Throws: `CRDTError` if preparation fails
    @discardableResult
    public func prepare(_ sql: String) throws -> OpaquePointer {
        return try prepareSQLOrThrow(db, sql)
    }

    /// Gets the underlying sqlite3* handle
    ///
    /// Use with caution - direct modifications bypass CRDT tracking
    public var rawDatabase: OpaquePointer {
        return db
    }

    /// Gets the current logical clock value
    ///
    /// - Returns: Current logical clock value (0 if no table is tracked)
    public var clock: UInt64 {
        get throws {
            guard let tableName = trackedTable else { return 0 }

            let clockTable = "_crdt_\(tableName)_clock"
            let sql = "SELECT time FROM \(clockTable)"

            let stmt = try prepareSQLOrThrow(db, sql)
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }

            return UInt64(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Gets the number of tombstones currently stored
    public var tombstoneCount: Int {
        get throws {
            guard let tableName = trackedTable else { return 0 }

            let tombstonesTable = "_crdt_\(tableName)_tombstones"
            let sql = "SELECT COUNT(*) FROM \(tombstonesTable)"

            let stmt = try prepareSQLOrThrow(db, sql)
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }

            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// Manually refresh schema metadata after ALTER TABLE
    ///
    /// Normally called automatically after execute(), but use this if you
    /// execute ALTER TABLE via raw sqlite3 API.
    public func refreshSchema() throws {
        guard let tableName = trackedTable else { return }

        // Re-cache column types
        try cacheColumnTypes(tableName: tableName)

        // Get current columns
        var columns: [String] = []
        let stmt = try prepareSQLOrThrow(db, "PRAGMA table_info(\(tableName))")
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                columns.append(String(cString: cString))
            }
        }

        // Recreate triggers
        try dropTriggers(tableName: tableName)
        try createTriggers(tableName: tableName, columns: columns, useIfNotExists: false)

        // Update column types table
        let typesTable = "_crdt_\(tableName)_types"
        for (colName, colType) in columnTypes {
            let sql = "INSERT OR REPLACE INTO \(typesTable) (col_name, col_type) VALUES (?, ?)"
            let stmt = try prepareSQLOrThrow(db, sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, colName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, colType)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Synchronization API

    /// Gets all changes since a given version
    ///
    /// - Parameters:
    ///   - version: Version to get changes since (0 for all changes)
    ///   - maxChanges: Maximum number of changes to return (0 = unlimited)
    /// - Returns: Array of changes that occurred after the given version
    /// - Throws: `CRDTError` on failure
    public func getChangesSince(_ version: UInt64, maxChanges: Int = 0) throws -> [Change<RecordID>] {
        return try getChangesSinceExcluding(version, excluding: [])
    }

    /// Gets changes since a version, excluding specific nodes
    ///
    /// - Parameters:
    ///   - version: Version to get changes since
    ///   - excluding: Set of node IDs to exclude (max 100 nodes)
    /// - Returns: Array of changes
    /// - Throws: `CRDTError` if excluding.count > 100
    public func getChangesSinceExcluding(_ version: UInt64, excluding: Set<UInt64>) throws -> [Change<RecordID>] {
        guard let tableName = trackedTable else {
            throw CRDTError.noTrackedTable
        }

        guard excluding.count <= CRDTConstants.maxExcludedNodes else {
            throw CRDTError.tooManyExcludedNodes(count: excluding.count, max: CRDTConstants.maxExcludedNodes)
        }

        var changes: [Change<RecordID>] = []

        // Query column changes from versions table
        var sql = """
            SELECT record_id, col_name, col_version, db_version, node_id, local_db_version
            FROM _crdt_\(tableName)_versions
            WHERE local_db_version > ?
            """

        if !excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: excluding.count).joined(separator: ",")
            sql += " AND node_id NOT IN (\(placeholders))"
        }

        sql += " ORDER BY local_db_version"

        let stmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(version))

        var paramIndex: Int32 = 2
        for nodeId in excluding {
            sqlite3_bind_int64(stmt, paramIndex, Int64(nodeId))
            paramIndex += 1
        }

        // Fetch column changes
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recordId = try readRecordId(from: stmt, column: 0)
            let colName = String(cString: sqlite3_column_text(stmt, 1))
            let colVersion = UInt64(sqlite3_column_int64(stmt, 2))
            let dbVersion = UInt64(sqlite3_column_int64(stmt, 3))
            let nodeId = UInt64(sqlite3_column_int64(stmt, 4))
            let localDbVersion = UInt64(sqlite3_column_int64(stmt, 5))

            // Query current value from main table
            let value = try queryColumnValue(tableName: tableName, recordId: recordId, columnName: colName)

            let change = Change(
                recordId: recordId,
                columnName: colName,
                value: value,
                columnVersion: colVersion,
                dbVersion: dbVersion,
                nodeId: nodeId,
                localDbVersion: localDbVersion
            )
            changes.append(change)
        }

        // Query tombstones
        sql = """
            SELECT record_id, db_version, node_id, local_db_version
            FROM _crdt_\(tableName)_tombstones
            WHERE local_db_version > ?
            """

        if !excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: excluding.count).joined(separator: ",")
            sql += " AND node_id NOT IN (\(placeholders))"
        }

        sql += " ORDER BY local_db_version"

        let tombstoneStmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(tombstoneStmt) }

        sqlite3_bind_int64(tombstoneStmt, 1, Int64(version))

        paramIndex = 2
        for nodeId in excluding {
            sqlite3_bind_int64(tombstoneStmt, paramIndex, Int64(nodeId))
            paramIndex += 1
        }

        while sqlite3_step(tombstoneStmt) == SQLITE_ROW {
            let recordId = try readRecordId(from: tombstoneStmt, column: 0)
            let dbVersion = UInt64(sqlite3_column_int64(tombstoneStmt, 1))
            let nodeId = UInt64(sqlite3_column_int64(tombstoneStmt, 2))
            let localDbVersion = UInt64(sqlite3_column_int64(tombstoneStmt, 3))

            let change = Change(
                recordId: recordId,
                columnName: nil,  // Tombstone
                value: nil,
                columnVersion: 0,
                dbVersion: dbVersion,
                nodeId: nodeId,
                localDbVersion: localDbVersion
            )
            changes.append(change)
        }

        // Sort by local_db_version to maintain causal order
        changes.sort { $0.localDbVersion < $1.localDbVersion }

        return changes
    }

    /// Merges changes from another node
    ///
    /// Applies changes using the CRDT merge rules, then updates the SQLite
    /// table to reflect accepted changes.
    ///
    /// - Parameter changes: Array of changes to merge
    /// - Returns: Array of accepted changes (those that won conflict resolution)
    /// - Throws: `CRDTError` on failure
    public func mergeChanges(_ changes: [Change<RecordID>]) throws -> [Change<RecordID>] {
        guard let tableName = trackedTable else {
            throw CRDTError.noTrackedTable
        }

        var acceptedChanges: [Change<RecordID>] = []

        // Process each change
        for remoteChange in changes {
            // Check if this is a tombstone
            if remoteChange.isTombstone {
                // Check local tombstone
                let sql = """
                    SELECT db_version, node_id FROM _crdt_\(tableName)_tombstones
                    WHERE record_id = ?
                    """
                let stmt = try prepareSQLOrThrow(db, sql)
                defer { sqlite3_finalize(stmt) }

                try bindRecordId(remoteChange.recordId, to: stmt, at: 1)

                if sqlite3_step(stmt) == SQLITE_ROW {
                    // Local tombstone exists, compare
                    let localDbVersion = UInt64(sqlite3_column_int64(stmt, 0))
                    let localNodeId = UInt64(sqlite3_column_int64(stmt, 1))

                    // Simple comparison: higher db_version wins, tie-break on node_id
                    if remoteChange.dbVersion > localDbVersion ||
                       (remoteChange.dbVersion == localDbVersion && remoteChange.nodeId > localNodeId) {
                        // Accept remote tombstone
                        try updateTombstone(tableName: tableName, change: remoteChange)
                        acceptedChanges.append(remoteChange)
                    }
                } else {
                    // No local tombstone, accept remote
                    try insertTombstone(tableName: tableName, change: remoteChange)
                    acceptedChanges.append(remoteChange)
                }
            } else {
                // Regular column change
                guard let columnName = remoteChange.columnName else { continue }

                // Query local version
                let sql = """
                    SELECT col_version, db_version, node_id FROM _crdt_\(tableName)_versions
                    WHERE record_id = ? AND col_name = ?
                    """
                let stmt = try prepareSQLOrThrow(db, sql)
                defer { sqlite3_finalize(stmt) }

                try bindRecordId(remoteChange.recordId, to: stmt, at: 1)
                sqlite3_bind_text(stmt, 2, columnName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                if sqlite3_step(stmt) == SQLITE_ROW {
                    // Local version exists, compare using LWW
                    let localColVersion = UInt64(sqlite3_column_int64(stmt, 0))
                    let localDbVersion = UInt64(sqlite3_column_int64(stmt, 1))
                    let localNodeId = UInt64(sqlite3_column_int64(stmt, 2))

                    let localChange = Change(
                        recordId: remoteChange.recordId,
                        columnName: columnName,
                        value: nil,
                        columnVersion: localColVersion,
                        dbVersion: localDbVersion,
                        nodeId: localNodeId
                    )

                    if Change.shouldAcceptRemote(local: localChange, remote: remoteChange) {
                        acceptedChanges.append(remoteChange)
                    }
                } else {
                    // No local version, accept remote
                    acceptedChanges.append(remoteChange)
                }
            }
        }

        // Apply accepted changes to SQLite
        if !acceptedChanges.isEmpty {
            try applyToSQLite(changes: acceptedChanges)
        }

        return acceptedChanges
    }

    /// Compacts tombstones older than the specified version
    ///
    /// Only call this when ALL nodes have acknowledged the minAcknowledgedVersion.
    /// Compacting too early may cause deleted records to reappear.
    ///
    /// - Parameter minAcknowledgedVersion: Minimum version acknowledged by all nodes
    /// - Returns: Number of tombstones removed
    /// - Throws: `CRDTError` on failure
    public func compactTombstones(minAcknowledgedVersion: UInt64) throws -> Int {
        guard let tableName = trackedTable else {
            throw CRDTError.noTrackedTable
        }

        let sql = """
            DELETE FROM _crdt_\(tableName)_tombstones
            WHERE db_version < ?
            """

        let stmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(minAcknowledgedVersion))
        sqlite3_step(stmt)

        return Int(sqlite3_changes(db))
    }

    // MARK: - Private Implementation (continued in next part...)
}

// MARK: - Private Methods Extension

extension CRDTSQLite {
    // Will be implemented in the next file...
}
