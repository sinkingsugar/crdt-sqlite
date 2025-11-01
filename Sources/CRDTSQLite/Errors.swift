// Errors.swift
// CRDT-SQLite error types

import Foundation

/// Errors that can occur during CRDT-SQLite operations
public enum CRDTError: Error, LocalizedError, CustomStringConvertible {
    case databaseOpenFailed(path: String, message: String)
    case executionFailed(sql: String, message: String, sqliteCode: Int32)
    case prepareFailed(sql: String, message: String, sqliteCode: Int32)
    case tableNameInvalid(String)
    case tableNameTooLong(String, maxLength: Int)
    case columnNameInvalid(String)
    case shadowTablesCreationFailed(tableName: String, message: String)
    case clockOverflow
    case tooManyExcludedNodes(count: Int, max: Int)
    case noTrackedTable
    case internalError(String)

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .databaseOpenFailed(let path, let message):
            return "Failed to open database at '\(path)': \(message)"
        case .executionFailed(let sql, let message, let code):
            return "SQL execution failed (code \(code)): \(message)\nSQL: \(sql)"
        case .prepareFailed(let sql, let message, let code):
            return "SQL prepare failed (code \(code)): \(message)\nSQL: \(sql)"
        case .tableNameInvalid(let name):
            return "Invalid table name: '\(name)' (must contain only alphanumeric characters and underscores)"
        case .tableNameTooLong(let name, let maxLength):
            return "Table name '\(name)' exceeds maximum length of \(maxLength) characters"
        case .columnNameInvalid(let name):
            return "Invalid column name: '\(name)' (must contain only alphanumeric characters and underscores)"
        case .shadowTablesCreationFailed(let tableName, let message):
            return "Failed to create shadow tables for '\(tableName)': \(message)"
        case .clockOverflow:
            return "Logical clock overflow detected (exceeded UInt64 maximum)"
        case .tooManyExcludedNodes(let count, let max):
            return "Too many excluded nodes: \(count) (maximum is \(max))"
        case .noTrackedTable:
            return "No table is being tracked. Call enableCRDT(for:) first."
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
