// SQLiteHelpers.swift
// RAII wrappers and helper functions for SQLite

import Foundation
import SQLite3

// MARK: - RAII Statement Wrapper

/// RAII wrapper for sqlite3_stmt* to ensure proper cleanup
///
/// Automatically finalizes the statement when it goes out of scope,
/// preventing memory leaks even when exceptions are thrown.
internal final class SQLiteStatement {
    private let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) {
        self.stmt = stmt
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    var raw: OpaquePointer {
        stmt
    }
}

// MARK: - SQL Validation

extension String {
    /// Validates that a table name is safe to use in SQL
    /// Prevents SQL injection by ensuring only alphanumeric characters and underscores
    var isValidTableName: Bool {
        guard !isEmpty else { return false }
        return allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Validates that a column name is safe to use in SQL
    var isValidColumnName: Bool {
        guard !isEmpty else { return false }
        return allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Escapes single quotes for SQL string literals
    var sqlEscaped: String {
        replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - SQLite Error Helper

extension OpaquePointer {
    /// Get the last error message from this database connection
    var lastErrorMessage: String {
        if let cString = sqlite3_errmsg(self) {
            return String(cString: cString)
        }
        return "Unknown error"
    }

    /// Get the last error code from this database connection
    var lastErrorCode: Int32 {
        sqlite3_errcode(self)
    }
}

// MARK: - Statement Execution Helper

/// Execute a SQL statement and return result code
@discardableResult
internal func executeSQL(_ db: OpaquePointer, _ sql: String) -> Int32 {
    var errorMsg: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)

    if let errorMsg = errorMsg {
        sqlite3_free(errorMsg)
    }

    return result
}

/// Execute SQL and throw if it fails
internal func executeSQLOrThrow(_ db: OpaquePointer, _ sql: String) throws {
    var errorMsg: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)

    if result != SQLITE_OK {
        let message: String
        if let errorMsg = errorMsg {
            message = String(cString: errorMsg)
            sqlite3_free(errorMsg)
        } else {
            message = db.lastErrorMessage
        }
        throw CRDTError.executionFailed(sql: sql, message: message, sqliteCode: result)
    }
}

/// Prepare a SQL statement and throw if it fails
internal func prepareSQLOrThrow(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)

    if result != SQLITE_OK {
        throw CRDTError.prepareFailed(sql: sql, message: db.lastErrorMessage, sqliteCode: result)
    }

    guard let stmt = stmt else {
        throw CRDTError.prepareFailed(sql: sql, message: "Statement is nil", sqliteCode: result)
    }

    return stmt
}

// MARK: - Processing Guard

/// RAII guard for boolean flags
///
/// Sets a flag to true on init, restores it to false on deinit.
/// Ensures flags are always reset even if exceptions occur.
internal final class ProcessingGuard {
    private let flag: UnsafeMutablePointer<Bool>

    init(_ flag: inout Bool) {
        self.flag = withUnsafeMutablePointer(to: &flag) { $0 }
        self.flag.pointee = true
    }

    deinit {
        flag.pointee = false
    }
}
