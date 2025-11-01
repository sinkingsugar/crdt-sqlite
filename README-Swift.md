# CRDT-SQLite Swift Package

A native Swift implementation of CRDT-SQLite, enabling automatic multi-node SQLite synchronization for iOS, macOS, tvOS, watchOS, and visionOS applications.

## Features

- ✅ **Native Swift API** - Idiomatic Swift with proper error handling and type safety
- ✅ **Codable Support** - Changes are automatically Codable for easy JSON serialization
- ✅ **Generic Record IDs** - Support for both Int64 (traditional) and UUID (distributed) record IDs
- ✅ **Type-Safe Values** - SQLiteValue enum provides safe SQLite value handling
- ✅ **Automatic Change Tracking** - Uses SQLite triggers and WAL hooks transparently
- ✅ **Column-Level Conflicts** - Fine-grained last-write-wins conflict resolution
- ✅ **Cross-Platform** - iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, visionOS 1+

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sinkingsugar/crdt-sqlite", from: "1.0.0")
]
```

Or in Xcode: File → Add Packages → Enter repository URL

## Quick Start

```swift
import CRDTSQLite

// Create database with unique node ID
let db = try CRDTSQLite<Int64>(path: "myapp.db", nodeId: 1)

// Create table and enable CRDT
try db.execute("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT,
        email TEXT
    )
""")
try db.enableCRDT(for: "users")

// Use normal SQL - changes are tracked automatically!
try db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")
try db.execute("UPDATE users SET email = 'alice.new@example.com' WHERE name = 'Alice'")

// Get changes since last sync
let changes = try db.getChangesSince(lastVersion)

// Serialize to JSON
let jsonData = try JSONEncoder().encode(changes)

// Send to other nodes...

// Merge incoming changes
let acceptedChanges = try db.mergeChanges(remoteChanges)
```

## Using UUID Record IDs

For distributed systems without coordination:

```swift
// Use UUID instead of Int64
let db = try CRDTSQLite<UUID>(path: "myapp.db", nodeId: 1)

try db.execute("""
    CREATE TABLE items (
        id BLOB PRIMARY KEY,
        title TEXT
    )
""")
try db.enableCRDT(for: "items")

// Generate UUIDs for new records
let uuid = UUID()
let stmt = try db.prepare("INSERT INTO items (id, title) VALUES (?, ?)")
defer { sqlite3_finalize(stmt) }

uuid.data.withUnsafeBytes { bytes in
    sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
}
sqlite3_bind_text(stmt, 2, "My Item", -1, SQLITE_TRANSIENT)
sqlite3_step(stmt)
```

## API Documentation

### Initialization

```swift
let db = try CRDTSQLite<RecordID>(path: String, nodeId: UInt64)
```

- `RecordID`: Either `Int64` or `UUID`
- `nodeId`: Unique identifier for this node (must be unique across all nodes)

### Core Operations

```swift
// Enable CRDT for a table
try db.enableCRDT(for: "tableName")

// Execute SQL
try db.execute("INSERT INTO users ...")

// Prepare statements
let stmt = try db.prepare("SELECT * FROM users WHERE id = ?")

// Get current logical clock
let clock = try db.clock

// Get tombstone count
let count = try db.tombstoneCount
```

### Synchronization

```swift
// Get all changes since a version
let changes = try db.getChangesSince(version)

// Get changes excluding specific nodes (bandwidth optimization)
let changes = try db.getChangesSinceExcluding(version, excluding: [nodeId1, nodeId2])

// Merge remote changes
let acceptedChanges = try db.mergeChanges(remoteChanges)

// Compact old tombstones (only when all nodes have acknowledged)
let removed = try db.compactTombstones(minAcknowledgedVersion: version)
```

## Change Structure

```swift
public struct Change<RecordID: CRDTRecordID>: Codable {
    public let recordId: RecordID
    public let columnName: String?  // nil = tombstone (entire record deleted)
    public let value: SQLiteValue?  // nil = column deletion
    public let columnVersion: UInt64
    public let dbVersion: UInt64
    public let nodeId: UInt64
    public let localDbVersion: UInt64
    public var flags: UInt32
}
```

### Properties

- `isTombstone`: True if this is a record deletion
- `isColumnDeletion`: True if this is a column deletion (set to NULL)
- `isColumnUpdate`: True if this is a regular column update

## SQLite Value Types

```swift
public enum SQLiteValue: Codable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
```

### Helper Methods

```swift
let value: SQLiteValue = .text("Hello")

// Bind to statement
value.bind(to: stmt, at: 1)

// Get underlying value
if let text = value.stringValue {
    print(text)
}

// SQL representation
print(value.sqlString)  // 'Hello'
```

## Error Handling

All errors are thrown as `CRDTError`:

```swift
do {
    try db.execute("INSERT INTO ...")
} catch CRDTError.executionFailed(let sql, let message, let code) {
    print("SQL failed: \(message)")
} catch {
    print("Other error: \(error)")
}
```

## Architecture

CRDT-SQLite uses a hybrid trigger + WAL hook architecture:

1. **Write Phase** (in transaction):
   - SQLite triggers populate `_pending` table
   - Fast, transactional, auto-rollback on error

2. **Processing Phase** (after commit):
   - WAL hook fires after commit with locks released
   - Updates shadow tables (`_versions`, `_tombstones`, `_clock`)
   - No lock contention

### Shadow Tables

For each CRDT-enabled table, the following shadow tables are created:

- `_crdt_<table>_versions` - Per-column version tracking
- `_crdt_<table>_tombstones` - Deleted record tracking
- `_crdt_<table>_clock` - Logical clock
- `_crdt_<table>_pending` - In-transaction change tracking
- `_crdt_<table>_types` - Column type information

## Thread Safety

⚠️ **Not thread-safe** - Use one CRDTSQLite instance per thread, or protect access with external synchronization.

## Conflict Resolution

Uses Last-Write-Wins (LWW) at column granularity:

1. Higher column version wins
2. If equal, higher db version wins
3. If equal, higher node ID wins

## Schema Changes

- ✅ **ALTER TABLE ADD COLUMN** - Fully supported, automatic
- ❌ **DROP TABLE** - Blocked (would orphan shadow tables)
- ⚠️ **RENAME TABLE** - Not recommended (breaks shadow tables)
- ⚠️ **DROP COLUMN** - Not supported (metadata corruption)
- ⚠️ **RENAME COLUMN** - Not supported (metadata corruption)

## Comparison with C++ Version

| Feature | C++ | Swift |
|---------|-----|-------|
| Core functionality | ✅ | ✅ |
| Performance | Baseline | ~10-20% overhead |
| Type safety | Good | Excellent |
| Error handling | Exceptions | Swift throws |
| JSON serialization | Manual | Automatic (Codable) |
| Memory management | Manual | Automatic (ARC) |
| Distribution | CMake | Swift PM |

## Example: Two-Node Sync

```swift
// Node 1
let db1 = try CRDTSQLite<Int64>(path: "node1.db", nodeId: 1)
try db1.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
try db1.enableCRDT(for: "users")
try db1.execute("INSERT INTO users (name) VALUES ('Alice')")

// Node 2
let db2 = try CRDTSQLite<Int64>(path: "node2.db", nodeId: 2)
try db2.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
try db2.enableCRDT(for: "users")
try db2.execute("INSERT INTO users (name) VALUES ('Bob')")

// Sync: Node 1 → Node 2
let changes1 = try db1.getChangesSince(0)
_ = try db2.mergeChanges(changes1)

// Sync: Node 2 → Node 1
let changes2 = try db2.getChangesSince(0)
_ = try db1.mergeChanges(changes2)

// Both nodes now have Alice and Bob!
```

## Testing

```bash
# Run tests
swift test

# Run specific test
swift test --filter CRDTSQLiteTests.testTwoNodeSync
```

## License

Same as parent project (see LICENSE)

## See Also

- [C++ Implementation](README.md) - Original C++ version
- [Architecture Documentation](README.md#architecture) - Detailed design docs
