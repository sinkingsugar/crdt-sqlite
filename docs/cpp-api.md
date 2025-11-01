# C++ API Reference

Complete C++ API documentation for CRDT-SQLite.

## Table of Contents

- [Installation](#installation)
- [Building](#building)
- [API Reference](#api-reference)
- [Threading Model](#threading-model)
- [Performance](#performance)
- [Windows Platform Notes](#windows-platform-notes)
- [Examples](#examples)

---

## Installation

### Prerequisites

- **C++20 compiler** (GCC 10+, Clang 13+, MSVC 2019+)
- **CMake 3.15+**
- **SQLite3 development libraries**

### Quick Install

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get install libsqlite3-dev cmake g++
```

**macOS:**
```bash
brew install sqlite cmake
```

**Windows:**
See [Windows Platform Notes](#windows-platform-notes) below.

---

## Building

### Standard Build

```bash
# Clone repository
git clone https://github.com/sinkingsugar/crdt-sqlite
cd crdt-sqlite

# Build
mkdir build && cd build
cmake .. -DBUILD_TESTS=ON
cmake --build .

# Run tests
ctest --output-on-failure
```

### CMake Options

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_TESTS` | OFF | Build test suite |
| `CMAKE_BUILD_TYPE` | Release | Build type (Release/Debug) |

### Integration

**CMakeLists.txt:**
```cmake
add_subdirectory(crdt-sqlite)
target_link_libraries(your_target PRIVATE crdt_sqlite)
```

Or use as header-only (include `crdt_sqlite.hpp` and `crdt_sqlite.cpp` in your project).

---

## API Reference

### Constructor

```cpp
CRDTSQLite(const char *path, CrdtNodeId node_id);
```

Creates a new CRDT-SQLite database instance.

**Parameters:**
- `path`: Path to SQLite database file (created if doesn't exist)
- `node_id`: Unique identifier for this node (must be unique across all syncing nodes)

**Example:**
```cpp
CRDTSQLite db("myapp.db", 1);
```

**Thread Safety:** Each instance is NOT thread-safe. Use one per thread or protect with mutex.

---

### Core Methods

#### `enable_crdt(const std::string &table_name)`

Enables CRDT synchronization for an existing table. Creates shadow tables and triggers.

**Schema Requirements:**
- Table must have a PRIMARY KEY (single column only)
- PRIMARY KEY can be INTEGER or BLOB (for UUIDs)

**What it creates:**
- `_crdt_<table>_versions` - Column version tracking
- `_crdt_<table>_tombstones` - Deletion tracking
- `_crdt_<table>_clock` - Logical clock
- `_crdt_<table>_pending` - Transaction-local change buffer
- Triggers: INSERT, UPDATE, DELETE on main table

**Example:**
```cpp
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)");
db.enable_crdt("users");

// Now all INSERT/UPDATE/DELETE are automatically tracked!
db.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')");
```

**Schema Change Support:**

| Operation | Status |
|-----------|--------|
| ALTER TABLE ADD COLUMN | ✅ Fully automatic |
| DROP TABLE | ❌ Blocked |
| RENAME TABLE | ⚠️ Not blocked but WILL BREAK |
| DROP/RENAME COLUMN | ⚠️ Not supported |

**Calling after ALTER TABLE ADD COLUMN:**
```cpp
db.execute("ALTER TABLE users ADD COLUMN age INTEGER");
db.refresh_schema();  // Required if not using execute()
```

---

#### `execute(const char *sql)`

Convenience wrapper for SQL execution with exception-based error handling.

**What it does:**
- Wraps `sqlite3_exec()`
- Throws `std::runtime_error` on failure
- Auto-calls `refresh_schema()` after ALTER TABLE

**Example:**
```cpp
try {
    db.execute("INSERT INTO users (name) VALUES ('Bob')");
} catch (const std::runtime_error &e) {
    std::cerr << "SQL error: " << e.what() << std::endl;
}
```

**Alternative: Use raw SQLite APIs directly**

Since triggers and `wal_hook` handle everything automatically, you can bypass `execute()`:

```cpp
// Option 1: execute() wrapper (convenient)
db.execute("INSERT INTO users (name) VALUES ('Alice')");

// Option 2: Raw sqlite3_exec() (also works!)
sqlite3_exec(db.get_db(), "INSERT INTO users (name) VALUES ('Bob')",
             nullptr, nullptr, nullptr);

// Option 3: Prepared statements (already exposed)
sqlite3_stmt *stmt = db.prepare("INSERT INTO users (name) VALUES (?)");
sqlite3_bind_text(stmt, 1, "Charlie", -1, SQLITE_STATIC);
sqlite3_step(stmt);
sqlite3_finalize(stmt);
```

**All three options work identically!** Triggers fire automatically, and `wal_hook` processes changes after commit.

**Caveat:** If using raw APIs with ALTER TABLE, call `refresh_schema()` manually:
```cpp
sqlite3_exec(db.get_db(), "ALTER TABLE users ADD COLUMN age INTEGER", ...);
db.refresh_schema();  // Manual call needed
```

---

#### `refresh_schema()`

Refreshes internal column metadata after schema changes.

**When to call:**
- After ALTER TABLE ADD COLUMN (if not using `execute()`)
- Typically at end of migration scripts

**Example:**
```cpp
sqlite3_exec(db.get_db(), "ALTER TABLE users ADD COLUMN age INTEGER", ...);
db.refresh_schema();
```

---

#### `prepare(const char *sql)`

Prepares a SQL statement for parameterized queries.

**Returns:** `sqlite3_stmt*` (caller must finalize)

**Example:**
```cpp
sqlite3_stmt *stmt = db.prepare("SELECT * FROM users WHERE id = ?");
sqlite3_bind_int64(stmt, 1, 42);

while (sqlite3_step(stmt) == SQLITE_ROW) {
    const char *name = (const char *)sqlite3_column_text(stmt, 1);
    std::cout << "Name: " << name << std::endl;
}

sqlite3_finalize(stmt);
```

---

#### `get_db()`

Returns raw `sqlite3*` handle for direct SQLite API access.

**Example:**
```cpp
sqlite3 *raw_db = db.get_db();
sqlite3_exec(raw_db, "PRAGMA journal_mode=WAL", nullptr, nullptr, nullptr);
```

---

### Synchronization Methods

#### `get_changes_since(uint64_t last_db_version, size_t max_changes = 0)`

Gets all changes since a given version.

**Parameters:**
- `last_db_version`: Get changes after this version (0 = all changes)
- `max_changes`: Limit number of changes (0 = no limit)

**Returns:** `std::vector<Change<RecordIDType>>`

**Change structure:**
```cpp
template <typename RecordIDType>
struct Change {
    RecordIDType record_id;
    std::string col_name;      // Empty for tombstones
    SQLiteValue value;
    uint64_t col_version;
    uint64_t db_version;
    uint64_t node_id;
    uint64_t local_db_version;
    uint32_t flags;
};
```

**Example:**
```cpp
auto changes = db.get_changes_since(last_sync_version);

for (const auto &change : changes) {
    if (change.is_tombstone()) {
        std::cout << "Record " << change.record_id << " deleted\n";
    } else {
        std::cout << "Record " << change.record_id
                  << ", column " << change.col_name
                  << " = " << change.value.to_string() << "\n";
    }
}
```

---

#### `merge_changes(std::vector<Change<...>> changes)`

Merges changes from another node using LWW conflict resolution.

**Parameters:**
- `changes`: Vector of changes from remote node

**Returns:** Vector of accepted changes (subset that won conflict resolution)

**Conflict Resolution:**
For each incoming change:
1. Compare `col_version` (higher wins)
2. If equal, compare `db_version` (higher wins)
3. If equal, compare `node_id` (higher wins = deterministic tie-breaker)

**Example:**
```cpp
// Receive changes from remote node
std::vector<Change<int64_t>> remote_changes = receive_from_network();

// Merge with LWW conflict resolution
auto accepted = db.merge_changes(remote_changes);

std::cout << "Accepted " << accepted.size() << " out of "
          << remote_changes.size() << " changes\n";
```

---

#### `compact_tombstones(uint64_t min_acknowledged_version)`

Removes old tombstones that all nodes have acknowledged.

⚠️ **CRITICAL**: Only call when ALL nodes have acknowledged the version!

**Parameters:**
- `min_acknowledged_version`: Safe to remove tombstones before this version

**Returns:** Number of tombstones removed

**Example:**
```cpp
// Track which version each node has acknowledged
std::map<uint64_t, uint64_t> node_acks;
node_acks[1] = 100;
node_acks[2] = 95;
node_acks[3] = 98;

// Find minimum
uint64_t min_ack = std::min({node_acks[1], node_acks[2], node_acks[3]});

// Safe to compact
uint64_t removed = db.compact_tombstones(min_ack);
std::cout << "Removed " << removed << " old tombstones\n";
```

**Why this matters:** Premature tombstone deletion allows deleted records to resurrect when syncing with nodes that haven't seen the deletion yet!

---

## Threading Model

⚠️ **CRDTSQLite is NOT thread-safe**

### Safe Usage Patterns

**Option 1: One instance per thread**
```cpp
// Thread 1
CRDTSQLite db1("myapp.db", 1);
db1.execute("INSERT INTO users ...");

// Thread 2 (separate connection)
CRDTSQLite db2("myapp.db", 1);
db2.execute("SELECT * FROM users ...");
```

**Option 2: External mutex**
```cpp
std::mutex db_mutex;
CRDTSQLite db("myapp.db", 1);

// Thread 1
{
    std::lock_guard<std::mutex> lock(db_mutex);
    db.execute("INSERT INTO users ...");
}

// Thread 2
{
    std::lock_guard<std::mutex> lock(db_mutex);
    auto changes = db.get_changes_since(0);
}
```

### SQLite Threading Configuration

CRDTSQLite opens databases with `SQLITE_OPEN_FULLMUTEX`:

```cpp
sqlite3_open_v2(path, &db_,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
    nullptr);
```

This enables SQLite's internal mutex protection, but **does not make CRDTSQLite thread-safe** (internal state is not protected).

---

## Performance

### Architecture Benefits

**Hypothesis:** Should be significantly faster than cr-sqlite because:

1. **Triggers are lightweight**
   - Only INSERT into `_pending` table (fast)
   - No heavy metadata computation during write

2. **Metadata updates happen asynchronously**
   - `wal_hook` fires AFTER commit with locks released
   - No blocking of concurrent writers

3. **Shorter critical section**
   - Less time holding write locks
   - Better concurrency

### Performance Comparison (Estimated)

| Approach | Lock Duration | Overhead | Crash Safe | Expected Perf |
|----------|---------------|----------|------------|---------------|
| **cr-sqlite** (pure triggers) | Long | High | Yes | Baseline |
| **update_hook + vector** | Short | Low | ❌ No | Fast but unsafe |
| **Ours** (triggers + wal_hook) | Short | Medium | ✅ Yes | **TBD** |

**Note:** Formal benchmarks comparing against cr-sqlite are planned but not yet completed.

---

## Windows Platform Notes

Windows CI builds SQLite from source with explicit threading flags to ensure consistent behavior.

### Building SQLite on Windows

```powershell
# Download SQLite amalgamation
Invoke-WebRequest -Uri "https://www.sqlite.org/2024/sqlite-amalgamation-3470200.zip" -OutFile sqlite.zip
Expand-Archive sqlite.zip

# Compile with FULLMUTEX threading
cd sqlite-amalgamation-*
cl /c /O2 /DSQLITE_THREADSAFE=1 sqlite3.c
lib /OUT:sqlite3.lib sqlite3.obj

# Copy to include/lib directories
copy sqlite3.h C:\include\
copy sqlite3.lib C:\lib\
```

### Why Custom Build?

vcpkg and other package managers may build SQLite with different threading modes (SQLITE_THREADSAFE=0 or SQLITE_THREADSAFE=2), which can cause:
- Mutex assertion failures
- Crashes in multi-threaded applications

Building from source with `SQLITE_THREADSAFE=1` ensures consistent FULLMUTEX mode.

---

## Examples

### Complete Two-Node Sync Example

```cpp
#include "crdt_sqlite.hpp"
#include <iostream>
#include <vector>

int main() {
    // Create two nodes
    CRDTSQLite db1("node1.db", 1);
    CRDTSQLite db2("node2.db", 2);

    // Setup schema on both nodes
    const char *schema = "CREATE TABLE IF NOT EXISTS users "
                        "(id INTEGER PRIMARY KEY, name TEXT, email TEXT)";

    db1.execute(schema);
    db1.enable_crdt("users");

    db2.execute(schema);
    db2.enable_crdt("users");

    // Node 1 writes
    db1.execute("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')");
    db1.execute("INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')");

    // Node 2 writes (concurrent)
    db2.execute("INSERT INTO users (name, email) VALUES ('Charlie', 'charlie@example.com')");

    // Sync: Node 1 → Node 2
    auto changes1 = db1.get_changes_since(0);
    std::cout << "Node 1 has " << changes1.size() << " changes\n";

    auto accepted1 = db2.merge_changes(changes1);
    std::cout << "Node 2 accepted " << accepted1.size() << " changes\n";

    // Sync: Node 2 → Node 1
    auto changes2 = db2.get_changes_since(0);
    std::cout << "Node 2 has " << changes2.size() << " changes\n";

    auto accepted2 = db1.merge_changes(changes2);
    std::cout << "Node 1 accepted " << accepted2.size() << " changes\n";

    // Both nodes now have Alice, Bob, and Charlie!
    auto print_users = [](CRDTSQLite &db, const char *label) {
        std::cout << "\n" << label << " users:\n";
        sqlite3_stmt *stmt = db.prepare("SELECT id, name, email FROM users");
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int64_t id = sqlite3_column_int64(stmt, 0);
            const char *name = (const char *)sqlite3_column_text(stmt, 1);
            const char *email = (const char *)sqlite3_column_text(stmt, 2);
            std::cout << "  ID " << id << ": " << name << " <" << email << ">\n";
        }
        sqlite3_finalize(stmt);
    };

    print_users(db1, "Node 1");
    print_users(db2, "Node 2");

    return 0;
}
```

### Conflict Resolution Example

```cpp
// Node 1 and Node 2 both update the same record concurrently

// Node 1 updates email
db1.execute("UPDATE users SET email = 'alice.new@example.com' WHERE id = 1");

// Node 2 updates name (concurrent - no coordination)
db2.execute("UPDATE users SET name = 'Alice Smith' WHERE id = 1");

// Sync both directions
auto changes1 = db1.get_changes_since(last_version);
db2.merge_changes(changes1);

auto changes2 = db2.get_changes_since(last_version);
db1.merge_changes(changes2);

// Result: BOTH changes are kept!
// - email = 'alice.new@example.com' (from Node 1)
// - name = 'Alice Smith' (from Node 2)
//
// No conflict because different columns were edited.
```

### UUID Record IDs Example

```cpp
#include "crdt_sqlite.hpp"
#include "record_id_types.hpp"
#include <random>

// Generate UUID
auto generate_uuid() -> std::array<uint8_t, 16> {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<uint64_t> dis;

    std::array<uint8_t, 16> uuid;
    uint64_t part1 = dis(gen);
    uint64_t part2 = dis(gen);

    memcpy(uuid.data(), &part1, 8);
    memcpy(uuid.data() + 8, &part2, 8);

    return uuid;
}

int main() {
    CRDTSQLite db("items.db", 1);

    // Create table with BLOB primary key
    db.execute("CREATE TABLE items (id BLOB PRIMARY KEY, title TEXT)");
    db.enable_crdt("items");

    // Insert with UUID
    auto uuid = generate_uuid();
    sqlite3_stmt *stmt = db.prepare("INSERT INTO items (id, title) VALUES (?, ?)");
    sqlite3_bind_blob(stmt, 1, uuid.data(), 16, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, "My Item", -1, SQLITE_STATIC);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    std::cout << "Inserted item with UUID\n";

    return 0;
}
```

---

## See Also

- [Main README](../README.md) - Overview and architecture
- [Swift API Reference](swift-api.md) - Swift implementation
- [CRDT Theory](https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type) - Background on CRDTs
