// CRDTSQLiteTests.swift
// Test suite for CRDT-SQLite Swift implementation

import XCTest
@testable import CRDTSQLite
import SQLite3

final class CRDTSQLiteTests: XCTestCase {
    var testDBPath: String!

    override func setUp() {
        super.setUp()
        // Create a unique temporary database for each test
        testDBPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    }

    override func tearDown() {
        // Clean up test database
        if FileManager.default.fileExists(atPath: testDBPath) {
            try? FileManager.default.removeItem(atPath: testDBPath)
        }
        super.tearDown()
    }

    // MARK: - Basic Tests

    func testDatabaseCreation() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)
        XCTAssertNotNil(db)

        // Verify WAL mode is enabled
        let stmt = try db.prepare("PRAGMA journal_mode")
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let mode = String(cString: sqlite3_column_text(stmt, 0))
        XCTAssertEqual(mode.uppercased(), "WAL")
    }

    func testEnableCRDT() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        // Create a test table
        try db.execute("""
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                name TEXT,
                email TEXT,
                age INTEGER
            )
            """)

        // Enable CRDT
        try db.enableCRDT(for: "users")

        // Verify shadow tables exist
        let tables = try getSQLiteTables(db: db.rawDatabase)
        XCTAssertTrue(tables.contains("_crdt_users_versions"))
        XCTAssertTrue(tables.contains("_crdt_users_tombstones"))
        XCTAssertTrue(tables.contains("_crdt_users_clock"))
        XCTAssertTrue(tables.contains("_crdt_users_pending"))
        XCTAssertTrue(tables.contains("_crdt_users_types"))

        // Verify clock is initialized
        let clock = try db.clock
        XCTAssertEqual(clock, 0)
    }

    func testInvalidTableName() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        XCTAssertThrowsError(try db.enableCRDT(for: "invalid-table-name")) { error in
            if case CRDTError.tableNameInvalid(let name) = error {
                XCTAssertEqual(name, "invalid-table-name")
            } else {
                XCTFail("Expected tableNameInvalid error")
            }
        }
    }

    func testTableNameTooLong() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)
        let longName = String(repeating: "a", count: 30)

        XCTAssertThrowsError(try db.enableCRDT(for: longName)) { error in
            if case CRDTError.tableNameTooLong(_, let maxLength) = error {
                XCTAssertEqual(maxLength, 23)
            } else {
                XCTFail("Expected tableNameTooLong error")
            }
        }
    }

    // MARK: - Single Node Operations

    func testSingleInsert() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
        try db.enableCRDT(for: "users")

        // Insert a record
        try db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")

        // Check clock advanced
        let clock = try db.clock
        XCTAssertGreaterThan(clock, 0)

        // Verify record exists
        let stmt = try db.prepare("SELECT name, email FROM users WHERE name = 'Alice'")
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "Alice")
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 1)), "alice@example.com")
    }

    func testSingleUpdate() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
        try db.enableCRDT(for: "users")

        // Insert and update
        try db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")
        let clockAfterInsert = try db.clock

        try db.execute("UPDATE users SET email = 'alice.new@example.com' WHERE name = 'Alice'")
        let clockAfterUpdate = try db.clock

        XCTAssertGreaterThan(clockAfterUpdate, clockAfterInsert)

        // Verify updated value
        let stmt = try db.prepare("SELECT email FROM users WHERE name = 'Alice'")
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "alice.new@example.com")
    }

    func testSingleDelete() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.enableCRDT(for: "users")

        // Insert and delete
        try db.execute("INSERT INTO users (name) VALUES ('Alice')")
        try db.execute("DELETE FROM users WHERE name = 'Alice'")

        // Verify record is gone
        let stmt = try db.prepare("SELECT COUNT(*) FROM users WHERE name = 'Alice'")
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0)

        // Verify tombstone exists
        let tombstoneCount = try db.tombstoneCount
        XCTAssertEqual(tombstoneCount, 1)
    }

    // MARK: - Synchronization Tests

    func testGetChangesSince() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
        try db.enableCRDT(for: "users")

        // Insert some records
        try db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")
        try db.execute("INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')")

        // Get all changes
        let changes = try db.getChangesSince(0)

        // Should have changes for both records (2 columns each = 4 changes)
        XCTAssertGreaterThanOrEqual(changes.count, 4)

        // Verify changes have correct structure
        for change in changes {
            XCTAssertNotNil(change.columnName)
            XCTAssertNotNil(change.value)
            XCTAssertEqual(change.nodeId, 1)
        }
    }

    func testGetChangesSinceExcludingNodes() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.enableCRDT(for: "users")

        try db.execute("INSERT INTO users (name) VALUES ('Alice')")

        // Get changes excluding node 1 (should be empty)
        let changesExcluding = try db.getChangesSinceExcluding(0, excluding: [1])
        XCTAssertEqual(changesExcluding.count, 0)

        // Get changes excluding node 2 (should have changes)
        let changesNotExcluding = try db.getChangesSinceExcluding(0, excluding: [2])
        XCTAssertGreaterThan(changesNotExcluding.count, 0)
    }

    func testTwoNodeSync() throws {
        // Create two nodes
        let dbPath1 = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let dbPath2 = NSTemporaryDirectory() + UUID().uuidString + ".db"

        defer {
            try? FileManager.default.removeItem(atPath: dbPath1)
            try? FileManager.default.removeItem(atPath: dbPath2)
        }

        let db1 = try CRDTSQLite<Int64>(path: dbPath1, nodeId: 1)
        let db2 = try CRDTSQLite<Int64>(path: dbPath2, nodeId: 2)

        // Set up same schema on both
        for db in [db1, db2] {
            try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
            try db.enableCRDT(for: "users")
        }

        // Node 1 inserts Alice
        try db1.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")

        // Node 2 inserts Bob
        try db2.execute("INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')")

        // Sync: db1 -> db2
        let changes1 = try db1.getChangesSince(0)
        _ = try db2.mergeChanges(changes1)

        // Sync: db2 -> db1
        let changes2 = try db2.getChangesSince(0)
        _ = try db1.mergeChanges(changes2)

        // Both should have both records
        for db in [db1, db2] {
            let stmt = try db.prepare("SELECT COUNT(*) FROM users")
            defer { sqlite3_finalize(stmt) }

            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(stmt, 0), 2)
        }
    }

    func testConflictResolution() throws {
        // Create two nodes
        let dbPath1 = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let dbPath2 = NSTemporaryDirectory() + UUID().uuidString + ".db"

        defer {
            try? FileManager.default.removeItem(atPath: dbPath1)
            try? FileManager.default.removeItem(atPath: dbPath2)
        }

        let db1 = try CRDTSQLite<Int64>(path: dbPath1, nodeId: 1)
        let db2 = try CRDTSQLite<Int64>(path: dbPath2, nodeId: 2)

        // Set up same schema on both
        for db in [db1, db2] {
            try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
            try db.enableCRDT(for: "users")
        }

        // Both insert a record with same ID
        try db1.execute("INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice1@example.com')")
        try db2.execute("INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice2@example.com')")

        // Node 2 updates email
        try db2.execute("UPDATE users SET email = 'alice.updated@example.com' WHERE id = 1")

        // Sync db2 -> db1
        let changes2 = try db2.getChangesSince(0)
        let accepted = try db1.mergeChanges(changes2)

        // Node 2's changes should win (higher version)
        XCTAssertGreaterThan(accepted.count, 0)
    }

    // MARK: - Tombstone Tests

    func testTombstoneCompaction() throws {
        let db = try CRDTSQLite<Int64>(path: testDBPath, nodeId: 1)

        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.enableCRDT(for: "users")

        // Insert and delete a record
        try db.execute("INSERT INTO users (name) VALUES ('Alice')")
        let clockAfterInsert = try db.clock

        try db.execute("DELETE FROM users WHERE name = 'Alice'")

        // Verify tombstone exists
        var tombstoneCount = try db.tombstoneCount
        XCTAssertEqual(tombstoneCount, 1)

        // Compact tombstones older than clock after insert
        let compacted = try db.compactTombstones(minAcknowledgedVersion: clockAfterInsert)

        // Tombstone should still be there (it's newer)
        tombstoneCount = try db.tombstoneCount
        XCTAssertEqual(tombstoneCount, 1)
        XCTAssertEqual(compacted, 0)

        // Compact with higher version
        let finalClock = try db.clock
        _ = try db.compactTombstones(minAcknowledgedVersion: finalClock + 1)

        // Tombstone should be gone
        tombstoneCount = try db.tombstoneCount
        XCTAssertEqual(tombstoneCount, 0)
    }

    // MARK: - Helper Methods

    private func getSQLiteTables(db: OpaquePointer) throws -> Set<String> {
        var tables = Set<String>()

        let stmt = try prepareSQLOrThrow(db, """
            SELECT name FROM sqlite_master WHERE type='table'
            """)
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                tables.insert(String(cString: cString))
            }
        }

        return tables
    }
}

// MARK: - UUID Tests

final class CRDTSQLiteUUIDTests: XCTestCase {
    var testDBPath: String!

    override func setUp() {
        super.setUp()
        testDBPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    }

    override func tearDown() {
        if FileManager.default.fileExists(atPath: testDBPath) {
            try? FileManager.default.removeItem(atPath: testDBPath)
        }
        super.tearDown()
    }

    func testUUIDRecordIDs() throws {
        let db = try CRDTSQLite<UUID>(path: testDBPath, nodeId: 1)

        try db.execute("""
            CREATE TABLE users (
                id BLOB PRIMARY KEY,
                name TEXT
            )
            """)
        try db.enableCRDT(for: "users")

        // Generate a UUID and insert
        let uuid = UUID()
        let uuidData = uuid.data

        let stmt = try db.prepare("INSERT INTO users (id, name) VALUES (?, 'Alice')")
        defer { sqlite3_finalize(stmt) }

        uuidData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(stmt)

        // Verify clock advanced
        let clock = try db.clock
        XCTAssertGreaterThan(clock, 0)

        // Get changes and verify UUID is preserved
        let changes = try db.getChangesSince(0)
        XCTAssertGreaterThan(changes.count, 0)

        // At least one change should have our UUID
        let hasOurUUID = changes.contains { $0.recordId == uuid }
        XCTAssertTrue(hasOurUUID, "Changes should contain our UUID")
    }
}
