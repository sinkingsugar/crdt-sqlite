// SQLiteValue.swift
// Type-safe representation of SQLite values

import Foundation
import SQLite3

/// Type-safe representation of SQLite values with full type information
///
/// Unlike the C++ version which uses a struct with a type tag, Swift's enum
/// with associated values provides better type safety and ergonomics.
public enum SQLiteValue: Codable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    // MARK: - SQLite Interop

    /// Create a SQLiteValue from a sqlite3_value pointer
    public static func from(sqliteValue: OpaquePointer) -> SQLiteValue {
        let type = sqlite3_value_type(sqliteValue)

        switch type {
        case SQLITE_NULL:
            return .null

        case SQLITE_INTEGER:
            return .integer(sqlite3_value_int64(sqliteValue))

        case SQLITE_FLOAT:
            return .real(sqlite3_value_double(sqliteValue))

        case SQLITE_TEXT:
            if let cString = sqlite3_value_text(sqliteValue) {
                return .text(String(cString: cString))
            } else {
                return .null
            }

        case SQLITE_BLOB:
            if let bytes = sqlite3_value_blob(sqliteValue) {
                let count = Int(sqlite3_value_bytes(sqliteValue))
                let data = Data(bytes: bytes, count: count)
                return .blob(data)
            } else {
                return .null
            }

        default:
            return .null
        }
    }

    /// Create a SQLiteValue from a column in a prepared statement
    public static func from(statement: OpaquePointer, column: Int32) -> SQLiteValue {
        let type = sqlite3_column_type(statement, column)

        switch type {
        case SQLITE_NULL:
            return .null

        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))

        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))

        case SQLITE_TEXT:
            if let cString = sqlite3_column_text(statement, column) {
                return .text(String(cString: cString))
            } else {
                return .null
            }

        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, column) {
                let count = Int(sqlite3_column_bytes(statement, column))
                let data = Data(bytes: bytes, count: count)
                return .blob(data)
            } else {
                return .null
            }

        default:
            return .null
        }
    }

    /// Bind this value to a prepared statement at the given index (1-based)
    @discardableResult
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case .null:
            return sqlite3_bind_null(statement, index)

        case .integer(let value):
            return sqlite3_bind_int64(statement, index, value)

        case .real(let value):
            return sqlite3_bind_double(statement, index, value)

        case .text(let value):
            return sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)

        case .blob(let value):
            return value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
        }
    }

    // MARK: - String Conversion

    /// Convert value to SQL string representation (for debugging)
    public var sqlString: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return String(value)
        case .real(let value):
            return String(value)
        case .text(let value):
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        case .blob(let data):
            return "X'\(data.map { String(format: "%02X", $0) }.joined())'"
        }
    }

    /// Get the SQLite type code for this value
    public var typeCode: Int32 {
        switch self {
        case .null: return SQLITE_NULL
        case .integer: return SQLITE_INTEGER
        case .real: return SQLITE_FLOAT
        case .text: return SQLITE_TEXT
        case .blob: return SQLITE_BLOB
        }
    }

    // MARK: - Type Checking

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var intValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .real(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}

// MARK: - CustomStringConvertible

extension SQLiteValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return "INTEGER(\(value))"
        case .real(let value):
            return "REAL(\(value))"
        case .text(let value):
            return "TEXT(\"\(value)\")"
        case .blob(let data):
            return "BLOB(\(data.count) bytes)"
        }
    }
}
