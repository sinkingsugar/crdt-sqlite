# CRDT-SQLite: Conflict-Free Replicated SQLite Database

A high-performance CRDT wrapper for SQLite that enables automatic multi-node synchronization with last-write-wins conflict resolution. Available in both **C++** and **Swift** with identical wire format compatibility.

## Why CRDT-SQLite?

- **Write Normal SQL**: Unlike cr-sqlite, use standard INSERT/UPDATE/DELETE (no virtual tables!)
- **Automatic Change Tracking**: SQLite triggers handle everything transparently
- **Column-Level Conflicts**: Fine-grained last-write-wins resolution per field
- **Cross-Platform**: C++ (Linux/macOS/Windows) and Swift (iOS/macOS/tvOS/watchOS/visionOS)
- **Wire Compatible**: C++ and Swift nodes can sync with each other seamlessly
- **Zero Code Changes**: Existing SQL applications work without modification

## Choose Your Language

### C++ Implementation
Best for: Desktop apps, servers, cross-platform tools, SQLite-heavy applications

**Key Features:**
- High performance with hybrid trigger + async processing
- Normal SQL writes (no special APIs required)
- CMake build system
- Raw SQLite API access

[📘 C++ API Documentation](docs/cpp-api.md)

### Swift Implementation
Best for: iOS, macOS, Apple ecosystem applications

**Key Features:**
- Native Swift API with proper error handling
- Codable support for automatic JSON serialization
- Generic record IDs (Int64 or UUID)
- Type-safe SQLiteValue enum
- Swift Package Manager integration

[📗 Swift API Documentation](docs/swift-api.md)

---

## Quick Start

### C++ Quick Start

```cpp
#include "crdt_sqlite.hpp"

// Create database with unique node ID
CRDTSQLite db("myapp.db", 1);

// Create table and enable CRDT
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)");
db.enable_crdt("users");

// Use normal SQL - changes are tracked automatically!
db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')");
db.execute("UPDATE users SET email = 'new@example.com' WHERE name = 'Alice'");

// Get changes since last sync
auto changes = db.get_changes_since(0);

// Merge incoming changes from other nodes
db.merge_changes(remote_changes);
```

[📘 Full C++ API Reference](docs/cpp-api.md)

### Swift Quick Start

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

// Get changes since last sync
let changes = try db.getChangesSince(lastVersion)

// Serialize to JSON (Codable!)
let jsonData = try JSONEncoder().encode(changes)

// Merge incoming changes from other nodes
let acceptedChanges = try db.mergeChanges(remoteChanges)
```

[📗 Full Swift API Reference](docs/swift-api.md)

---

## Architecture: Triggers + WAL Hook

CRDT-SQLite uses a **hybrid trigger + WAL hook** architecture that combines crash safety with high performance:

```
┌─────────────────────────────────────────────────┐
│  User: INSERT INTO users (name) VALUES ('Bob')  │
└─────────────────────────────────────────────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │  SQLite Trigger Fires  │
         │  (INSERT/UPDATE/DELETE)│
         └────────────────────────┘
                      │
                      ▼
  ┌────────────────────────────────────────┐
  │  Trigger: INSERT INTO _pending         │
  │    (operation, record_id)              │
  │  ✓ Fast (just one INSERT)              │
  │  ✓ Transactional (auto-rollback)       │
  └────────────────────────────────────────┘
                      │
                      ▼ COMMIT happens
         ┌────────────────────────┐
         │  WAL Checkpoint         │
         │  Locks RELEASED         │
         └────────────────────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │  wal_hook() fires       │
         │  (AFTER commit)         │
         └────────────────────────┘
                      │
                      ▼
  ┌────────────────────────────────────────┐
  │  process_pending_changes()              │
  │  1. Read _pending table                 │
  │  2. Query current row values            │
  │  3. Update _versions shadow table       │
  │  4. Increment _clock                    │
  │  5. Delete from _pending                │
  │  ✓ NO locks held (wal_hook is safe!)   │
  └────────────────────────────────────────┘
```

**Key Insight**: The `wal_hook` callback fires **AFTER** commit with all locks released, enabling fast metadata updates without blocking writers.

---

## Shadow Tables

When you enable CRDT for a table (e.g., `users`), four shadow tables are automatically created:

### 1. `_crdt_users_versions`
Tracks the version of each column:
```sql
CREATE TABLE _crdt_users_versions (
  record_id INTEGER,
  col_name TEXT,
  col_version INTEGER,   -- Per-column edit counter
  db_version INTEGER,    -- Global logical clock
  node_id INTEGER,       -- Which node made this change
  local_db_version INTEGER,  -- Local clock when applied
  PRIMARY KEY (record_id, col_name)
);
```

### 2. `_crdt_users_tombstones`
Tracks deleted records:
```sql
CREATE TABLE _crdt_users_tombstones (
  record_id INTEGER PRIMARY KEY,
  db_version INTEGER,
  node_id INTEGER,
  local_db_version INTEGER
);
```

### 3. `_crdt_users_clock`
Logical clock for causality tracking:
```sql
CREATE TABLE _crdt_users_clock (
  time INTEGER PRIMARY KEY
);
```

### 4. `_crdt_users_pending`
Temporary table for tracking changes within transactions:
```sql
CREATE TABLE _crdt_users_pending (
  operation INTEGER,
  record_id INTEGER,
  PRIMARY KEY (operation, record_id)
);
```

---

## Conflict Resolution

### Last-Write-Wins (LWW)

Conflicts are resolved **per-column** using three-way comparison:

1. **Column version** (higher wins)
2. **DB version** (higher wins if column versions equal)
3. **Node ID** (deterministic tie-breaker)

**Example:**
```cpp
// Node 1 updates email
db1.execute("UPDATE users SET email = 'alice@foo.com' WHERE id = 1");

// Node 2 updates name (concurrent edit)
db2.execute("UPDATE users SET name = 'Alice Smith' WHERE id = 1");

// After sync: BOTH changes are kept!
// Different columns don't conflict - fine-grained resolution!
```

---

## Synchronization Workflow

Both C++ and Swift implementations follow the same pattern:

1. **Get changes** from local database since last sync version
2. **Send changes** to remote nodes (over network, JSON, protobuf, etc.)
3. **Receive changes** from remote nodes
4. **Merge changes** using LWW conflict resolution
5. **Compact tombstones** when all nodes have acknowledged (optional)

**Wire Format Compatibility**: C++ and Swift nodes can sync with each other - they use identical shadow table schemas and serialization formats.

---

## Threading Model

⚠️ **Neither implementation is thread-safe**

**Safe usage patterns:**
- One instance per thread (each with own database connection)
- Protect ALL access with external mutex
- Both use `SQLITE_OPEN_FULLMUTEX` for proper SQLite mutex protection

---

## Schema Changes

| Operation | Support Level |
|-----------|---------------|
| **ALTER TABLE ADD COLUMN** | ✅ Fully supported, automatic |
| **DROP TABLE** | ❌ Blocked (would orphan shadow tables) |
| **RENAME TABLE** | ⚠️ Not blocked but WILL BREAK shadow tables |
| **DROP COLUMN** | ⚠️ Not supported (metadata corruption) |
| **RENAME COLUMN** | ⚠️ Not supported (metadata corruption) |

---

## Installation & Building

### C++ Installation

**Prerequisites:**
- C++20 compiler
- CMake 3.15+
- SQLite3 development libraries

**Build Instructions:**
```bash
mkdir build && cd build
cmake .. -DBUILD_TESTS=ON
cmake --build .
ctest --output-on-failure
```

[📘 Full C++ Build Documentation](docs/cpp-api.md#building)

### Swift Installation

**Swift Package Manager:**

Add to your `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/sinkingsugar/crdt-sqlite", from: "1.0.0")
]
```

Or in Xcode: **File → Add Packages → Enter repository URL**

**Platform Support:**
- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+
- visionOS 1+

[📗 Full Swift Installation Guide](docs/swift-api.md#installation)

---

## Comparison with cr-sqlite

| Feature | **CRDT-SQLite** (Ours) | cr-sqlite |
|---------|------------------------|-----------|
| **Write API** | ✅ Normal SQL (INSERT/UPDATE/DELETE) | ❌ Virtual tables (special functions required) |
| **Read API** | ✅ Normal SELECT | ✅ Normal SELECT |
| **CRDT metadata access** | C++/Swift APIs | ✅ SQL queries (via virtual tables) |
| **Architecture** | Triggers + wal_hook | Virtual tables + triggers |
| **Learning curve** | Low (just SQL) | Higher (learn cr-sqlite API) |
| **Existing code** | Works unchanged | Requires rewrite |
| **Performance** | TBD (benchmarks pending) | Established baseline |

**Key advantage:** Our trigger-based approach means you write normal SQL - no special APIs, no virtual tables, no code changes. Just enable CRDT on a table and keep writing SQL like you always have.

---

## Performance Notes

### C++ Performance

**Hypothesis**: Should be significantly faster than cr-sqlite because:
- Triggers only INSERT into `_pending` (minimal work during write)
- Heavy metadata updates happen in wal_hook AFTER locks released
- Shorter critical section = less contention

**Note**: Formal benchmarks comparing against cr-sqlite are planned but not yet completed.

### Swift Performance

The Swift implementation has an estimated ~10-20% overhead compared to C++ due to:
- ARC memory management
- Swift/C bridging for SQLite calls
- Type-safe value wrapping

For most applications, the ergonomic benefits of Swift (Codable, type safety, error handling) outweigh this small overhead.

---

## Related Projects

- **[crdt-lite](https://github.com/your-org/crdt-lite)** - Lightweight in-memory CRDT library (header-only C++ and Rust)
  - Pure algorithmic CRDT implementations
  - No persistence, no dependencies
  - Text CRDT for collaborative editing
  - Use crdt-lite for: in-memory state, game sync, real-time collaboration
  - Use crdt-sqlite for: persistent storage, database-backed apps, SQLite integration

---

## Documentation

- [📘 C++ API Reference](docs/cpp-api.md) - Complete C++ API, threading, Windows notes
- [📗 Swift API Reference](docs/swift-api.md) - Complete Swift API, Codable, UUID support
- [🔄 Swift Implementation Status](docs/SWIFT_IMPLEMENTATION.md) - Feature parity tracking
- [❓ Swift FAQ](docs/SWIFT_FAQ.md) - Platform support, troubleshooting

---

## License

MIT License - see LICENSE file for details
