# Swift API Reference

Complete Swift API documentation for CRDT-SQLite.

## Table of Contents

- [Installation](#installation)
- [Platform Support](#platform-support)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Record ID Types](#record-id-types)
- [SQLite Values](#sqlite-values)
- [Change Structure](#change-structure)
- [Error Handling](#error-handling)
- [Examples](#examples)

---

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sinkingsugar/crdt-sqlite", from: "1.0.0")
]

// Then add to your target:
targets: [
    .target(
        name: "YourApp",
        dependencies: ["CRDTSQLite"]
    )
]
```

### Xcode

1. **File → Add Packages...**
2. Enter repository URL: `https://github.com/sinkingsugar/crdt-sqlite`
3. Select version/branch
4. Click **Add Package**

### Import

```swift
import CRDTSQLite
```

---

## Platform Support

| Platform | Minimum Version |
|----------|----------------|
| iOS | 13.0+ |
| macOS | 10.15+ |
| tvOS | 13.0+ |
| watchOS | 6.0+ |
| visionOS | 1.0+ |
| Linux | Swift 5.9+ |

**SQLite Dependency:** Uses system-provided SQLite3 (libsqlite3.dylib on Apple platforms).

---

## Quick Start

### Basic Example (Int64 Record IDs)

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

// Serialize to JSON (automatic via Codable)
let jsonData = try JSONEncoder().encode(changes)

// Send to other nodes...

// Merge incoming changes
let acceptedChanges = try db.mergeChanges(remoteChanges)
print("Accepted \(acceptedChanges.count) changes")
```

---

## API Reference

### Initialization

```swift
init(path: String, nodeId: UInt64) throws
```

Creates a new CRDT-SQLite database instance.

**Parameters:**
- `path`: Path to SQLite database file (created if doesn't exist)
- `nodeId`: Unique identifier for this node (must be unique across all syncing nodes)

**Generic Parameter:**
- `RecordID`: Either `Int64` or `UUID`

**Throws:** `CRDTError` if database cannot be opened

**Examples:**

```swift
// Int64 record IDs (traditional auto-increment)
let db = try CRDTSQLite<Int64>(path: "myapp.db", nodeId: 1)

// UUID record IDs (distributed, no coordination needed)
let db = try CRDTSQLite<UUID>(path: "myapp.db", nodeId: 1)
```

---

### Core Operations

#### `enableCRDT(for tableName: String)`

Enables CRDT synchronization for an existing table.

**Parameters:**
- `tableName`: Name of the table to enable CRDT for

**Throws:** `CRDTError` if table doesn't exist or shadow tables can't be created

**Requirements:**
- Table must have a PRIMARY KEY (single column)
- PRIMARY KEY must be INTEGER (for Int64) or BLOB (for UUID)

**Example:**
```swift
try db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT)")
try db.enableCRDT(for: "posts")
```

---

#### `execute(_ sql: String)`

Executes SQL with exception-based error handling.

**Parameters:**
- `sql`: SQL statement to execute

**Throws:** `CRDTError.executionFailed` with details

**Example:**
```swift
do {
    try db.execute("INSERT INTO users (name) VALUES ('Bob')")
} catch CRDTError.executionFailed(let sql, let message, let code) {
    print("SQL failed: \(message)")
    print("SQL: \(sql)")
    print("Error code: \(code)")
}
```

---

#### `prepare(_ sql: String)`

Prepares a SQL statement for parameterized queries.

**Parameters:**
- `sql`: SQL statement with optional `?` placeholders

**Returns:** `OpaquePointer` (sqlite3_stmt pointer - caller must finalize)

**Throws:** `CRDTError` if preparation fails

**Example:**
```swift
let stmt = try db.prepare("SELECT * FROM users WHERE id = ?")
defer { sqlite3_finalize(stmt) }

sqlite3_bind_int64(stmt, 1, 42)

while sqlite3_step(stmt) == SQLITE_ROW {
    let name = String(cString: sqlite3_column_text(stmt, 1))
    print("Name: \(name)")
}
```

---

### Properties

#### `clock: UInt64`

Returns the current logical clock value.

**Example:**
```swift
let currentClock = try db.clock
print("Current logical time: \(currentClock)")
```

---

#### `tombstoneCount: Int`

Returns the number of tombstones (deleted records) across all CRDT tables.

**Example:**
```swift
let tombstones = try db.tombstoneCount
print("Tombstones to compact: \(tombstones)")
```

---

### Synchronization

#### `getChangesSince(_ version: UInt64, maxChanges: Int = 0)`

Gets all changes since a given version.

**Parameters:**
- `version`: Get changes after this version (0 = all changes)
- `maxChanges`: Limit number of changes (0 = no limit)

**Returns:** `[Change<RecordID>]`

**Throws:** `CRDTError` if query fails

**Example:**
```swift
let changes = try db.getChangesSince(lastSyncVersion)

for change in changes {
    if change.isTombstone {
        print("Record \(change.recordId) was deleted")
    } else {
        print("Record \(change.recordId), column \(change.columnName ?? "?") updated")
    }
}
```

---

#### `getChangesSinceExcluding(_ version: UInt64, excluding: [UInt64], maxChanges: Int = 0)`

Gets changes since a version, excluding specific nodes (bandwidth optimization).

**Parameters:**
- `version`: Get changes after this version
- `excluding`: Array of node IDs to exclude from results
- `maxChanges`: Limit number of changes (0 = no limit)

**Returns:** `[Change<RecordID>]`

**Use case:** When syncing with Node B, exclude changes that originated from Node B (they already have them).

**Example:**
```swift
// Syncing with node 2 - don't send changes that came from node 2
let changes = try db.getChangesSinceExcluding(
    lastSyncVersion,
    excluding: [2]  // Node 2's ID
)

// Send only relevant changes to node 2
sendToNode2(changes)
```

---

#### `mergeChanges(_ changes: [Change<RecordID>])`

Merges changes from another node using LWW conflict resolution.

**Parameters:**
- `changes`: Array of changes from remote node

**Returns:** `[Change<RecordID>]` - subset that won conflict resolution

**Throws:** `CRDTError` if merge fails

**Conflict Resolution:**
1. Compare `columnVersion` (higher wins)
2. If equal, compare `dbVersion` (higher wins)
3. If equal, compare `nodeId` (higher wins)

**Example:**
```swift
// Receive changes from network
let remoteChanges = try JSONDecoder().decode([Change<Int64>].self, from: jsonData)

// Merge with local database
let accepted = try db.mergeChanges(remoteChanges)

print("Accepted \(accepted.count) out of \(remoteChanges.count) changes")
```

---

#### `compactTombstones(minAcknowledgedVersion version: UInt64)`

Removes old tombstones that all nodes have acknowledged.

⚠️ **CRITICAL**: Only call when ALL nodes have acknowledged the version!

**Parameters:**
- `version`: Safe to remove tombstones before this version

**Returns:** `Int` - number of tombstones removed

**Throws:** `CRDTError` if compaction fails

**Example:**
```swift
// Track which version each node has acknowledged
let nodeAcks: [UInt64: UInt64] = [
    1: 100,
    2: 95,
    3: 98
]

// Find minimum acknowledged version
let minAck = nodeAcks.values.min() ?? 0

// Safe to compact
let removed = try db.compactTombstones(minAcknowledgedVersion: minAck)
print("Removed \(removed) old tombstones")
```

**Why this matters:** Premature deletion allows deleted records to resurrect when syncing with nodes that haven't seen the deletion!

---

## Record ID Types

CRDT-SQLite supports two record ID types via generics.

### Int64 (Traditional)

Best for: Single-node ID generation, coordinated systems

```swift
let db = try CRDTSQLite<Int64>(path: "myapp.db", nodeId: 1)

try db.execute("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT
    )
""")
try db.enableCRDT(for: "users")

// SQLite auto-generates IDs
try db.execute("INSERT INTO users (name) VALUES ('Alice')")
```

**Pros:**
- Simple and familiar
- Compact (8 bytes)
- Auto-increment support

**Cons:**
- Requires coordination for ID generation across nodes
- Risk of ID collisions in distributed systems

---

### UUID (Distributed)

Best for: Multi-node systems, offline-first apps, no coordination

```swift
import Foundation

let db = try CRDTSQLite<UUID>(path: "myapp.db", nodeId: 1)

try db.execute("""
    CREATE TABLE items (
        id BLOB PRIMARY KEY,
        title TEXT
    )
""")
try db.enableCRDT(for: "items")

// Generate UUID for new record
let uuid = UUID()
let stmt = try db.prepare("INSERT INTO items (id, title) VALUES (?, ?)")
defer { sqlite3_finalize(stmt) }

// Bind UUID as BLOB
uuid.data.withUnsafeBytes { bytes in
    sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
}
sqlite3_bind_text(stmt, 2, "My Item", -1, SQLITE_TRANSIENT)
sqlite3_step(stmt)
```

**Pros:**
- No coordination needed
- Globally unique
- Perfect for distributed systems

**Cons:**
- Larger (16 bytes)
- No auto-increment
- Manual ID generation required

---

## SQLite Values

The `SQLiteValue` enum provides type-safe handling of SQLite values.

### Enum Cases

```swift
public enum SQLiteValue: Codable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
```

### Usage

#### Creating Values

```swift
let value1: SQLiteValue = .text("Hello")
let value2: SQLiteValue = .integer(42)
let value3: SQLiteValue = .real(3.14)
let value4: SQLiteValue = .blob(Data([0x01, 0x02, 0x03]))
let value5: SQLiteValue = .null
```

#### Extracting Values

```swift
let value: SQLiteValue = .text("Hello")

// Type-safe extraction
if let text = value.stringValue {
    print("String: \(text)")
}

// Properties
print(value.intValue)     // Optional<Int64>
print(value.doubleValue)  // Optional<Double>
print(value.stringValue)  // Optional<String>
print(value.blobValue)    // Optional<Data>
```

#### Binding to Statements

```swift
let stmt = try db.prepare("INSERT INTO users (name, age) VALUES (?, ?)")
defer { sqlite3_finalize(stmt) }

let name: SQLiteValue = .text("Alice")
let age: SQLiteValue = .integer(30)

name.bind(to: stmt, at: 1)
age.bind(to: stmt, at: 2)

sqlite3_step(stmt)
```

#### SQL String Representation

```swift
let value: SQLiteValue = .text("Hello")
print(value.sqlString)  // 'Hello'

let num: SQLiteValue = .integer(42)
print(num.sqlString)    // 42

let null: SQLiteValue = .null
print(null.sqlString)   // NULL
```

---

## Change Structure

```swift
public struct Change<RecordID: CRDTRecordID>: Codable {
    public let recordId: RecordID
    public let columnName: String?     // nil = tombstone (record deleted)
    public let value: SQLiteValue?     // nil = column deletion (set to NULL)
    public let columnVersion: UInt64
    public let dbVersion: UInt64
    public let nodeId: UInt64
    public let localDbVersion: UInt64
    public var flags: UInt32
}
```

### Properties

#### Computed Properties

```swift
public var isTombstone: Bool        // True if entire record deleted
public var isColumnDeletion: Bool   // True if column set to NULL
public var isColumnUpdate: Bool     // True if regular column update
```

#### Examples

```swift
let changes = try db.getChangesSince(0)

for change in changes {
    if change.isTombstone {
        print("🗑️ Record \(change.recordId) deleted")
    } else if change.isColumnDeletion {
        print("❌ Record \(change.recordId), column \(change.columnName!) set to NULL")
    } else {
        print("✏️ Record \(change.recordId), column \(change.columnName!) = \(change.value!)")
    }
}
```

### Codable Support

Changes are automatically Codable for easy JSON serialization:

```swift
// Serialize to JSON
let changes = try db.getChangesSince(0)
let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
let jsonData = try encoder.encode(changes)

// Send over network
sendToServer(jsonData)

// Deserialize from JSON
let decoder = JSONDecoder()
let remoteChanges = try decoder.decode([Change<Int64>].self, from: jsonData)

// Merge
let accepted = try db.mergeChanges(remoteChanges)
```

---

## Error Handling

All errors are thrown as `CRDTError`.

### Error Types

```swift
public enum CRDTError: Error {
    case databaseOpenFailed(String, Int32)
    case executionFailed(String, String, Int32)
    case prepareFailed(String, String, Int32)
    case unexpectedNullValue(String)
    case transactionFailed(String)
    case invalidRecordIDType
}
```

### Handling Errors

```swift
do {
    try db.execute("INSERT INTO users (name) VALUES ('Alice')")
} catch CRDTError.executionFailed(let sql, let message, let code) {
    print("SQL execution failed")
    print("SQL: \(sql)")
    print("Error: \(message)")
    print("Code: \(code)")
} catch CRDTError.databaseOpenFailed(let path, let code) {
    print("Failed to open database at \(path)")
    print("Error code: \(code)")
} catch {
    print("Other error: \(error)")
}
```

### Error Messages

All `CRDTError` cases conform to `LocalizedError`:

```swift
do {
    try db.execute("INVALID SQL")
} catch {
    print(error.localizedDescription)
    // Prints human-readable error message
}
```

---

## Examples

### Two-Node Sync Example

```swift
import CRDTSQLite
import Foundation

// Create two nodes
let db1 = try CRDTSQLite<Int64>(path: "node1.db", nodeId: 1)
let db2 = try CRDTSQLite<Int64>(path: "node2.db", nodeId: 2)

// Setup schema on both nodes
let schema = """
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        name TEXT,
        email TEXT
    )
"""

try db1.execute(schema)
try db1.enableCRDT(for: "users")

try db2.execute(schema)
try db2.enableCRDT(for: "users")

// Node 1 writes
try db1.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')")
try db1.execute("INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')")

// Node 2 writes (concurrent)
try db2.execute("INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com')")

// Sync: Node 1 → Node 2
let changes1 = try db1.getChangesSince(0)
print("Node 1 has \(changes1.count) changes")

let accepted1 = try db2.mergeChanges(changes1)
print("Node 2 accepted \(accepted1.count) changes")

// Sync: Node 2 → Node 1
let changes2 = try db2.getChangesSince(0)
print("Node 2 has \(changes2.count) changes")

let accepted2 = try db1.mergeChanges(changes2)
print("Node 1 accepted \(accepted2.count) changes")

// Both nodes now have Alice, Bob, and Charlie!
```

---

### Conflict Resolution Example

```swift
// Setup
let db1 = try CRDTSQLite<Int64>(path: "node1.db", nodeId: 1)
let db2 = try CRDTSQLite<Int64>(path: "node2.db", nodeId: 2)

// ... setup schema and enable CRDT ...

// Insert initial record on both nodes (synced)
try db1.execute("INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@example.com')")
let initialChanges = try db1.getChangesSince(0)
_ = try db2.mergeChanges(initialChanges)

// Concurrent conflicting updates
// Node 1 updates email
try db1.execute("UPDATE users SET email = 'alice.new@example.com' WHERE id = 1")

// Node 2 updates name (no coordination!)
try db2.execute("UPDATE users SET name = 'Alice Smith' WHERE id = 1")

// Sync both directions
let changes1 = try db1.getChangesSince(initialChanges.last!.dbVersion)
_ = try db2.mergeChanges(changes1)

let changes2 = try db2.getChangesSince(initialChanges.last!.dbVersion)
_ = try db1.mergeChanges(changes2)

// Result: BOTH changes are kept!
// - email = 'alice.new@example.com' (from Node 1)
// - name = 'Alice Smith' (from Node 2)
//
// No conflict because different columns were edited.
```

---

### Network Sync Example (JSON)

```swift
import Foundation

struct SyncMessage: Codable {
    let nodeId: UInt64
    let changes: [Change<Int64>]
}

// Sender
func sendChangesToServer(db: CRDTSQLite<Int64>, lastSyncVersion: UInt64) async throws {
    let changes = try db.getChangesSince(lastSyncVersion)

    let message = SyncMessage(nodeId: db.nodeId, changes: changes)
    let jsonData = try JSONEncoder().encode(message)

    // Send to server
    var request = URLRequest(url: URL(string: "https://api.example.com/sync")!)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (_, response) = try await URLSession.shared.data(for: request)
    // ... handle response ...
}

// Receiver
func receiveChangesFromServer(db: CRDTSQLite<Int64>) async throws {
    let url = URL(string: "https://api.example.com/sync")!
    let (data, _) = try await URLSession.shared.data(from: url)

    let message = try JSONDecoder().decode(SyncMessage.self, from: data)

    let accepted = try db.mergeChanges(message.changes)
    print("Accepted \(accepted.count) changes from node \(message.nodeId)")
}
```

---

### iOS App Example

```swift
import SwiftUI
import CRDTSQLite

class TodoStore: ObservableObject {
    private let db: CRDTSQLite<UUID>

    @Published var todos: [Todo] = []

    init() throws {
        // Open database
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let dbPath = documentsPath.appendingPathComponent("todos.db").path

        // Use UUID for distributed IDs
        db = try CRDTSQLite<UUID>(path: dbPath, nodeId: 1)

        // Setup schema
        try db.execute("""
            CREATE TABLE IF NOT EXISTS todos (
                id BLOB PRIMARY KEY,
                title TEXT NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0
            )
        """)
        try db.enableCRDT(for: "todos")

        // Load todos
        loadTodos()
    }

    func loadTodos() {
        // ... query and populate todos array ...
    }

    func addTodo(title: String) throws {
        let uuid = UUID()
        let stmt = try db.prepare("INSERT INTO todos (id, title, completed) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }

        uuid.data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, 0)

        sqlite3_step(stmt)
        loadTodos()
    }

    func sync() async throws {
        // Get local changes
        let changes = try db.getChangesSince(lastSyncVersion)

        // Send to server and receive remote changes
        // ...

        // Merge remote changes
        let accepted = try db.mergeChanges(remoteChanges)
        print("Accepted \(accepted.count) changes")

        loadTodos()
    }
}

struct Todo {
    let id: UUID
    var title: String
    var completed: Bool
}
```

---

## See Also

- [Main README](../README.md) - Overview and architecture
- [C++ API Reference](cpp-api.md) - C++ implementation
- [Swift Implementation Status](SWIFT_IMPLEMENTATION.md) - Feature parity tracking
- [Swift FAQ](SWIFT_FAQ.md) - Troubleshooting and platform notes
