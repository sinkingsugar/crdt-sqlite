// CRDTSQLite+Private.swift
// Private implementation methods

import Foundation
import SQLite3

extension CRDTSQLite {
    // MARK: - Shadow Tables

    internal func createShadowTables(tableName: String) throws {
        let recordIdType = RecordID.self == Int64.self ? "INTEGER" : "BLOB"

        // Create versions table
        let versionsTable = "_crdt_\(tableName)_versions"
        let createVersions = """
            CREATE TABLE IF NOT EXISTS \(versionsTable) (
                record_id \(recordIdType) NOT NULL,
                col_name TEXT NOT NULL,
                col_version INTEGER NOT NULL,
                db_version INTEGER NOT NULL,
                node_id INTEGER NOT NULL,
                local_db_version INTEGER NOT NULL,
                PRIMARY KEY (record_id, col_name)
            )
            """
        try executeSQLOrThrow(db, createVersions)

        // Create index on local_db_version for efficient sync queries
        try executeSQLOrThrow(db, """
            CREATE INDEX IF NOT EXISTS \(versionsTable)_local_db_version_idx
            ON \(versionsTable)(local_db_version)
            """)

        // Create tombstones table
        let tombstonesTable = "_crdt_\(tableName)_tombstones"
        let createTombstones = """
            CREATE TABLE IF NOT EXISTS \(tombstonesTable) (
                record_id \(recordIdType) PRIMARY KEY,
                db_version INTEGER NOT NULL,
                node_id INTEGER NOT NULL,
                local_db_version INTEGER NOT NULL
            )
            """
        try executeSQLOrThrow(db, createTombstones)

        try executeSQLOrThrow(db, """
            CREATE INDEX IF NOT EXISTS \(tombstonesTable)_local_db_version_idx
            ON \(tombstonesTable)(local_db_version)
            """)

        // Create clock table
        let clockTable = "_crdt_\(tableName)_clock"
        try executeSQLOrThrow(db, """
            CREATE TABLE IF NOT EXISTS \(clockTable) (
                time INTEGER NOT NULL
            )
            """)

        // Initialize clock if empty
        let checkStmt = try prepareSQLOrThrow(db, "SELECT COUNT(*) FROM \(clockTable)")
        defer { sqlite3_finalize(checkStmt) }

        sqlite3_step(checkStmt)
        let count = sqlite3_column_int(checkStmt, 0)

        if count == 0 {
            try executeSQLOrThrow(db, "INSERT INTO \(clockTable) VALUES (0)")
        }

        // Create pending changes table
        let pendingTable = "_crdt_\(tableName)_pending"
        try executeSQLOrThrow(db, """
            CREATE TABLE IF NOT EXISTS \(pendingTable) (
                operation INTEGER NOT NULL,
                record_id \(recordIdType) NOT NULL,
                col_name TEXT NOT NULL DEFAULT '',
                PRIMARY KEY (operation, record_id, col_name)
            )
            """)

        // Create column types table
        let typesTable = "_crdt_\(tableName)_types"
        try executeSQLOrThrow(db, """
            CREATE TABLE IF NOT EXISTS \(typesTable) (
                col_name TEXT PRIMARY KEY,
                col_type INTEGER NOT NULL
            )
            """)

        // Store column types
        for (colName, colType) in columnTypes {
            let stmt = try prepareSQLOrThrow(db, """
                INSERT OR REPLACE INTO \(typesTable) (col_name, col_type) VALUES (?, ?)
                """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, colName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, colType)
            sqlite3_step(stmt)
        }

        // Get column names for trigger creation
        var columns: [String] = []
        let stmt = try prepareSQLOrThrow(db, "PRAGMA table_info(\(tableName))")
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                columns.append(String(cString: cString))
            }
        }

        // Create triggers
        try createTriggers(tableName: tableName, columns: columns, useIfNotExists: true)
    }

    internal func createTriggers(tableName: String, columns: [String], useIfNotExists: Bool) throws {
        let pendingTable = "_crdt_\(tableName)_pending"
        let createClause = useIfNotExists ? "CREATE TRIGGER IF NOT EXISTS" : "CREATE TRIGGER"

        // Determine ID column reference
        let idColNew = RecordID.self == Int64.self ? "NEW.rowid" : "NEW.id"
        let idColOld = RecordID.self == Int64.self ? "OLD.rowid" : "OLD.id"

        // INSERT trigger - track all columns as changed
        let insertStatements = columns.map { col in
            "    INSERT OR REPLACE INTO \(pendingTable) (operation, record_id, col_name)\n" +
            "    VALUES (\(OperationType.insert.rawValue), \(idColNew), '\(col)');"
        }.joined(separator: "\n")

        let insertTrigger = """
            \(createClause) _crdt_\(tableName)_insert
            AFTER INSERT ON \(tableName)
            BEGIN
            \(insertStatements)
            END
            """
        try executeSQLOrThrow(db, insertTrigger)

        // UPDATE trigger - only track changed columns
        let updateStatements = columns.map { col in
            "    INSERT OR REPLACE INTO \(pendingTable) (operation, record_id, col_name)\n" +
            "    SELECT \(OperationType.update.rawValue), \(idColNew), '\(col)'\n" +
            "    WHERE OLD.\(col) IS NOT NEW.\(col);"
        }.joined(separator: "\n")

        let updateTrigger = """
            \(createClause) _crdt_\(tableName)_update
            AFTER UPDATE ON \(tableName)
            BEGIN
            \(updateStatements)
            END
            """
        try executeSQLOrThrow(db, updateTrigger)

        // DELETE trigger - col_name is empty string
        let deleteTrigger = """
            \(createClause) _crdt_\(tableName)_delete
            BEFORE DELETE ON \(tableName)
            BEGIN
                INSERT OR REPLACE INTO \(pendingTable) (operation, record_id, col_name)
                VALUES (\(OperationType.delete.rawValue), \(idColOld), '');
            END
            """
        try executeSQLOrThrow(db, deleteTrigger)
    }

    internal func dropTriggers(tableName: String) throws {
        try executeSQLOrThrow(db, "DROP TRIGGER IF EXISTS _crdt_\(tableName)_insert")
        try executeSQLOrThrow(db, "DROP TRIGGER IF EXISTS _crdt_\(tableName)_update")
        try executeSQLOrThrow(db, "DROP TRIGGER IF EXISTS _crdt_\(tableName)_delete")
    }

    // MARK: - Column Type Caching

    internal func cacheColumnTypes(tableName: String) throws {
        columnTypes.removeAll()

        let stmt = try prepareSQLOrThrow(db, "PRAGMA table_info(\(tableName))")
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let colNameC = sqlite3_column_text(stmt, 1),
                  let colTypeC = sqlite3_column_text(stmt, 2) else {
                continue
            }

            let colName = String(cString: colNameC)
            let colTypeStr = String(cString: colTypeC).uppercased()

            // Map SQL type to SQLite type code
            let colType: Int32
            if colTypeStr.contains("INT") {
                colType = SQLITE_INTEGER
            } else if colTypeStr.contains("REAL") || colTypeStr.contains("FLOAT") || colTypeStr.contains("DOUBLE") {
                colType = SQLITE_FLOAT
            } else if colTypeStr.contains("BLOB") {
                colType = SQLITE_BLOB
            } else {
                colType = SQLITE_TEXT
            }

            columnTypes[colName] = colType
        }
    }

    // MARK: - Query Methods

    internal func queryColumnValue(tableName: String, recordId: RecordID, columnName: String) throws -> SQLiteValue? {
        let idColumn = RecordID.self == Int64.self ? "rowid" : "id"
        let sql = "SELECT \(columnName) FROM \(tableName) WHERE \(idColumn) = ?"

        let stmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(stmt) }

        try bindRecordId(recordId, to: stmt, at: 1)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return SQLiteValue.from(statement: stmt, column: 0)
    }

    // MARK: - Apply Changes

    internal func applyToSQLite(changes: [Change<RecordID>]) throws {
        guard let tableName = trackedTable else { return }

        // Drop triggers to prevent recursive tracking
        try dropTriggers(tableName: tableName)

        // Get columns for trigger recreation
        var columns: [String] = []
        let stmt = try prepareSQLOrThrow(db, "PRAGMA table_info(\(tableName))")
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                columns.append(String(cString: cString))
            }
        }
        sqlite3_finalize(stmt)

        // Ensure triggers are restored even if error occurs
        defer {
            do {
                try createTriggers(tableName: tableName, columns: columns, useIfNotExists: false)
            } catch {
                print("CRITICAL: Failed to restore triggers for \(tableName): \(error)")
            }
        }

        // Get current clock
        var currentClock = try clock

        // Apply each change
        for change in changes {
            if change.isTombstone {
                // Delete record
                try insertTombstone(tableName: tableName, change: change)

                // Also delete from main table
                let idColumn = RecordID.self == Int64.self ? "rowid" : "id"
                let deleteStmt = try prepareSQLOrThrow(db, "DELETE FROM \(tableName) WHERE \(idColumn) = ?")
                defer { sqlite3_finalize(deleteStmt) }

                try bindRecordId(change.recordId, to: deleteStmt, at: 1)
                sqlite3_step(deleteStmt)
            } else {
                guard let columnName = change.columnName else { continue }

                // Validate column name to prevent SQL injection
                guard columnName.isValidColumnName else {
                    throw CRDTError.internalError("Invalid column name in change: \(columnName)")
                }

                // Check if record exists
                let idColumn = RecordID.self == Int64.self ? "rowid" : "id"
                let checkStmt = try prepareSQLOrThrow(db, "SELECT 1 FROM \(tableName) WHERE \(idColumn) = ?")
                defer { sqlite3_finalize(checkStmt) }

                try bindRecordId(change.recordId, to: checkStmt, at: 1)
                let exists = sqlite3_step(checkStmt) == SQLITE_ROW

                if exists {
                    // Update existing record
                    let updateSQL = "UPDATE \(tableName) SET \(columnName) = ? WHERE \(idColumn) = ?"
                    let updateStmt = try prepareSQLOrThrow(db, updateSQL)
                    defer { sqlite3_finalize(updateStmt) }

                    _ = change.value?.bind(to: updateStmt, at: 1) ?? sqlite3_bind_null(updateStmt, 1)
                    try bindRecordId(change.recordId, to: updateStmt, at: 2)
                    sqlite3_step(updateStmt)
                } else {
                    // Insert new record with just the ID and this column
                    // CRDT builds up records column-by-column
                    // Use INSERT OR IGNORE in case concurrent changes create the row
                    let insertSQL = "INSERT OR IGNORE INTO \(tableName) (\(idColumn), \(columnName)) VALUES (?, ?)"
                    let insertStmt = try prepareSQLOrThrow(db, insertSQL)
                    defer { sqlite3_finalize(insertStmt) }

                    try bindRecordId(change.recordId, to: insertStmt, at: 1)
                    _ = change.value?.bind(to: insertStmt, at: 2) ?? sqlite3_bind_null(insertStmt, 2)
                    let result = sqlite3_step(insertStmt)

                    // If INSERT OR IGNORE didn't insert (row already exists), do an UPDATE
                    if result == SQLITE_DONE && sqlite3_changes(db) == 0 {
                        let updateSQL = "UPDATE \(tableName) SET \(columnName) = ? WHERE \(idColumn) = ?"
                        let updateStmt = try prepareSQLOrThrow(db, updateSQL)
                        defer { sqlite3_finalize(updateStmt) }

                        _ = change.value?.bind(to: updateStmt, at: 1) ?? sqlite3_bind_null(updateStmt, 1)
                        try bindRecordId(change.recordId, to: updateStmt, at: 2)
                        sqlite3_step(updateStmt)
                    }
                }

                // Update version table
                guard currentClock < UInt64.max else {
                    throw CRDTError.clockOverflow
                }
                currentClock += 1
                try updateVersionTable(
                    tableName: tableName,
                    recordId: change.recordId,
                    columnName: columnName,
                    colVersion: change.columnVersion,
                    dbVersion: change.dbVersion,
                    nodeId: change.nodeId,
                    localDbVersion: currentClock
                )
            }
        }

        // Update clock
        let clockTable = "_crdt_\(tableName)_clock"
        try executeSQLOrThrow(db, "UPDATE \(clockTable) SET time = \(currentClock)")
    }

    // MARK: - Tombstone Operations

    internal func insertTombstone(tableName: String, change: Change<RecordID>) throws {
        let tombstonesTable = "_crdt_\(tableName)_tombstones"
        let sql = """
            INSERT OR REPLACE INTO \(tombstonesTable) (record_id, db_version, node_id, local_db_version)
            VALUES (?, ?, ?, ?)
            """

        let stmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(stmt) }

        try bindRecordId(change.recordId, to: stmt, at: 1)
        sqlite3_bind_int64(stmt, 2, Int64(change.dbVersion))
        sqlite3_bind_int64(stmt, 3, Int64(change.nodeId))
        sqlite3_bind_int64(stmt, 4, Int64(change.localDbVersion))

        sqlite3_step(stmt)
    }

    internal func updateTombstone(tableName: String, change: Change<RecordID>) throws {
        try insertTombstone(tableName: tableName, change: change)
    }

    internal func updateVersionTable(
        tableName: String,
        recordId: RecordID,
        columnName: String,
        colVersion: UInt64,
        dbVersion: UInt64,
        nodeId: UInt64,
        localDbVersion: UInt64
    ) throws {
        let versionsTable = "_crdt_\(tableName)_versions"
        let sql = """
            INSERT OR REPLACE INTO \(versionsTable)
            (record_id, col_name, col_version, db_version, node_id, local_db_version)
            VALUES (?, ?, ?, ?, ?, ?)
            """

        let stmt = try prepareSQLOrThrow(db, sql)
        defer { sqlite3_finalize(stmt) }

        try bindRecordId(recordId, to: stmt, at: 1)
        sqlite3_bind_text(stmt, 2, columnName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, Int64(colVersion))
        sqlite3_bind_int64(stmt, 4, Int64(dbVersion))
        sqlite3_bind_int64(stmt, 5, Int64(nodeId))
        sqlite3_bind_int64(stmt, 6, Int64(localDbVersion))

        sqlite3_step(stmt)
    }

    // MARK: - Change Processing

    internal func processPendingChanges() {
        guard let tableName = trackedTable else { return }

        // Prevent re-entry from nested WAL callbacks
        // NOTE: Not thread-safe - this class must not be used from multiple threads
        guard !processingWalChanges else { return }

        processingWalChanges = true
        defer { processingWalChanges = false }

        do {
            // Get current clock
            var currentClock = try clock

            // Query pending changes
            let pendingTable = "_crdt_\(tableName)_pending"
            let stmt = try prepareSQLOrThrow(db, """
                SELECT operation, record_id, col_name FROM \(pendingTable)
                """)
            defer { sqlite3_finalize(stmt) }

            var pendingChanges: [(operation: Int32, recordId: RecordID, columnName: String)] = []

            while sqlite3_step(stmt) == SQLITE_ROW {
                let operation = sqlite3_column_int(stmt, 0)
                let recordId = try readRecordId(from: stmt, column: 1)
                let colName = String(cString: sqlite3_column_text(stmt, 2))

                pendingChanges.append((operation, recordId, colName))
            }

            // Process each pending change
            for (operation, recordId, columnName) in pendingChanges {
                if operation == OperationType.delete.rawValue {
                    // Handle delete (tombstone)
                    guard currentClock < UInt64.max else {
                        throw CRDTError.clockOverflow
                    }
                    currentClock += 1

                    let tombstonesTable = "_crdt_\(tableName)_tombstones"
                    let insertStmt = try prepareSQLOrThrow(db, """
                        INSERT OR REPLACE INTO \(tombstonesTable) (record_id, db_version, node_id, local_db_version)
                        VALUES (?, ?, ?, ?)
                        """)
                    defer { sqlite3_finalize(insertStmt) }

                    try bindRecordId(recordId, to: insertStmt, at: 1)
                    sqlite3_bind_int64(insertStmt, 2, Int64(currentClock))
                    sqlite3_bind_int64(insertStmt, 3, Int64(nodeId))
                    sqlite3_bind_int64(insertStmt, 4, Int64(currentClock))

                    sqlite3_step(insertStmt)
                } else {
                    // Handle insert/update
                    // Get current col_version for this column
                    let versionsTable = "_crdt_\(tableName)_versions"
                    let versionStmt = try prepareSQLOrThrow(db, """
                        SELECT col_version FROM \(versionsTable)
                        WHERE record_id = ? AND col_name = ?
                        """)
                    defer { sqlite3_finalize(versionStmt) }

                    try bindRecordId(recordId, to: versionStmt, at: 1)
                    sqlite3_bind_text(versionStmt, 2, columnName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                    var colVersion: UInt64 = 0
                    if sqlite3_step(versionStmt) == SQLITE_ROW {
                        colVersion = UInt64(sqlite3_column_int64(versionStmt, 0))
                    }

                    // Increment version counters
                    colVersion += 1
                    guard currentClock < UInt64.max else {
                        throw CRDTError.clockOverflow
                    }
                    currentClock += 1

                    // Update version table
                    try updateVersionTable(
                        tableName: tableName,
                        recordId: recordId,
                        columnName: columnName,
                        colVersion: colVersion,
                        dbVersion: currentClock,
                        nodeId: nodeId,
                        localDbVersion: currentClock
                    )
                }
            }

            // Clear pending table
            try executeSQLOrThrow(db, "DELETE FROM \(pendingTable)")

            // Update clock
            let clockTable = "_crdt_\(tableName)_clock"
            try executeSQLOrThrow(db, "UPDATE \(clockTable) SET time = \(currentClock)")

        } catch {
            print("Error processing pending changes: \(error)")
        }
    }

    // MARK: - SQLite Callbacks

    internal func authorizerCallback(action: Int32, arg1: UnsafePointer<CChar>?, arg2: UnsafePointer<CChar>?, arg3: UnsafePointer<CChar>?, arg4: UnsafePointer<CChar>?) -> Int32 {
        // Detect ALTER TABLE
        if action == SQLITE_ALTER_TABLE {
            pendingSchemaRefresh = true
        }
        return SQLITE_OK
    }

    internal func walCallback(numPages: Int32) {
        processPendingChanges()
    }

    internal func rollbackCallback() {
        guard let tableName = trackedTable else { return }

        // Clear pending table on rollback
        let pendingTable = "_crdt_\(tableName)_pending"
        do {
            try executeSQLOrThrow(db, "DELETE FROM \(pendingTable)")
        } catch {
            print("Error clearing pending table on rollback: \(error)")
        }
    }

    // MARK: - Record ID Helpers

    internal func readRecordId(from stmt: OpaquePointer, column: Int32) throws -> RecordID {
        if RecordID.self == Int64.self {
            return sqlite3_column_int64(stmt, column) as! RecordID
        } else if RecordID.self == UUID.self {
            guard let blob = sqlite3_column_blob(stmt, column) else {
                throw CRDTError.internalError("Failed to read UUID from column \(column)")
            }
            let count = Int(sqlite3_column_bytes(stmt, column))
            let data = Data(bytes: blob, count: count)

            guard let uuid = UUID(data: data) else {
                throw CRDTError.internalError("Failed to create UUID from data")
            }
            return uuid as! RecordID
        } else {
            throw CRDTError.internalError("Unsupported RecordID type")
        }
    }

    internal func bindRecordId(_ recordId: RecordID, to stmt: OpaquePointer, at index: Int32) throws {
        if RecordID.self == Int64.self {
            let int64Value = recordId as! Int64
            sqlite3_bind_int64(stmt, index, int64Value)
        } else if RecordID.self == UUID.self {
            let uuid = recordId as! UUID
            let data = uuid.data
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            throw CRDTError.internalError("Unsupported RecordID type")
        }
    }
}
