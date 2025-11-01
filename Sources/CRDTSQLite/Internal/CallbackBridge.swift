// CallbackBridge.swift
// Type-erased callback bridge for SQLite hooks

import Foundation
import SQLite3

/// Protocol for callback handling
internal protocol CRDTCallbackHandler: AnyObject {
    func authorizerCallback(action: Int32, arg1: UnsafePointer<CChar>?, arg2: UnsafePointer<CChar>?, arg3: UnsafePointer<CChar>?, arg4: UnsafePointer<CChar>?) -> Int32
    func walCallback(numPages: Int32)
    func rollbackCallback()
}

/// Type-erased box for storing callback handler references
internal final class CallbackBox {
    weak var handler: CRDTCallbackHandler?

    init(handler: CRDTCallbackHandler) {
        self.handler = handler
    }
}

// MARK: - C Function Callbacks
//
// SAFETY: These C callbacks MUST NOT throw or crash.
// All Swift handler methods MUST handle their own errors internally.

internal func crdtAuthorizerCallback(
    ctx: UnsafeMutableRawPointer?,
    action: Int32,
    arg1: UnsafePointer<CChar>?,
    arg2: UnsafePointer<CChar>?,
    arg3: UnsafePointer<CChar>?,
    arg4: UnsafePointer<CChar>?
) -> Int32 {
    guard let ctx = ctx else { return SQLITE_OK }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let handler = box.handler else { return SQLITE_OK }
    return handler.authorizerCallback(action: action, arg1: arg1, arg2: arg2, arg3: arg3, arg4: arg4)
}

internal func crdtWalCallback(
    ctx: UnsafeMutableRawPointer?,
    db: OpaquePointer?,
    dbName: UnsafePointer<CChar>?,
    numPages: Int32
) -> Int32 {
    guard let ctx = ctx else { return SQLITE_OK }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let handler = box.handler else { return SQLITE_OK }
    handler.walCallback(numPages: numPages)
    return SQLITE_OK
}

internal func crdtRollbackCallback(
    ctx: UnsafeMutableRawPointer?
) {
    guard let ctx = ctx else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let handler = box.handler else { return }
    handler.rollbackCallback()
}
