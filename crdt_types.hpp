// crdt_types.hpp - Minimal CRDT type definitions for SQLite wrapper
#ifndef CRDT_TYPES_HPP
#define CRDT_TYPES_HPP

#include <cstdint>
#include <string>
#include <unordered_set>
#include <optional>

// Node identifier type
using CrdtNodeId = uint64_t;

// Column key type (field name)
using CrdtKey = std::string;

// Set type
template <typename K, typename Hash = std::hash<K>, typename KeyEqual = std::equal_to<K>>
using CrdtSet = std::unordered_set<K, Hash, KeyEqual>;

/// Represents a single change in the CRDT.
/// This structure is used for synchronization between nodes.
template <typename K, typename V> struct Change {
  K record_id;
  std::optional<CrdtKey> col_name; // std::nullopt represents tombstone of the record
  std::optional<V> value;          // std::nullopt represents deletion of the column
  uint64_t col_version;            // Per-column version counter
  uint64_t db_version;             // Global logical clock at change creation
  CrdtNodeId node_id;              // Node that created this change

  // Local db_version when change was applied (for sync optimization)
  uint64_t local_db_version;

  // Ephemeral flags (not persisted, used during processing)
  uint32_t flags;

  Change() = default;

  Change(K rid, std::optional<CrdtKey> cname, std::optional<V> val, uint64_t cver, uint64_t dver, CrdtNodeId nid,
         uint64_t ldb_ver = 0, uint32_t f = 0)
      : record_id(std::move(rid)), col_name(std::move(cname)), value(std::move(val)), col_version(cver), db_version(dver),
        node_id(nid), local_db_version(ldb_ver), flags(f) {}
};

#endif // CRDT_TYPES_HPP
