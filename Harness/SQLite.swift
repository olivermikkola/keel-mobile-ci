import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A failed SQLite call. The message comes from SQLite and never contains
/// bound values, only SQL text positions and names.
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// The smallest wrapper the workspace needs: one serialized connection,
/// prepared statements with bound values only, and typed column reads.
/// SQL text is always a constant in this package; values are always bound.
final class SQLiteDatabase {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        var flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        #if os(iOS)
        // SQLITE_OPEN_FILEPROTECTION_COMPLETE: unreadable while the phone is locked.
        flags |= 0x0010_0000
        #endif
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: code, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements that take no values and return no rows.
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(code) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(code) }
        return SQLiteStatement(database: self, handle: statement)
    }

    /// Prepares the first statement in `sql` that starts at `offset`. `sql` is NUL-terminated UTF-8.
    /// The statement is nil when only spaces or comments remain. `next` is the offset after it.
    func prepare(bytes sql: [CChar], offset: Int) throws -> (statement: SQLiteStatement?, next: Int) {
        var statement: OpaquePointer?
        var next = sql.count
        let code = sql.withUnsafeBufferPointer { buffer -> Int32 in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(handle, buffer.baseAddress! + offset, -1, &statement, &tail)
            if let tail { next = buffer.baseAddress!.distance(to: tail) }
            return code
        }
        guard code == SQLITE_OK else { throw error(code) }
        return (statement.map { SQLiteStatement(database: self, handle: $0) }, next)
    }

    /// Runs one statement with bound values and discards any rows.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    /// Runs one statement and calls `row` for every result row.
    func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteStatement) throws -> Void) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() { try row(statement) }
    }

    func scalar(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteValue? {
        var result: SQLiteValue?
        let statement = try prepare(sql)
        try statement.bind(values)
        if try statement.step() { result = statement.value(0) }
        return result
    }

    /// All-or-nothing: any thrown error rolls the whole block back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    /// Rows changed by every statement since the connection opened. Diff it around a statement.
    var totalChanges: Int { Int(sqlite3_total_changes(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    fileprivate static var transientDestructor: sqlite3_destructor_type { transient }
}

final class SQLiteStatement {
    private let database: SQLiteDatabase
    let handle: OpaquePointer

    fileprivate init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(handle, index)
            case .integer(let number): code = sqlite3_bind_int64(handle, index, number)
            case .real(let number): code = sqlite3_bind_double(handle, index, number)
            case .text(let text): code = sqlite3_bind_text(handle, index, text, -1, SQLiteDatabase.transientDestructor)
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    // A zero-length blob needs a non-null pointer, or SQLite stores NULL.
                    if bytes.count == 0 { return sqlite3_bind_zeroblob(handle, index, 0) }
                    return sqlite3_bind_blob64(handle, index, bytes.baseAddress, sqlite3_uint64(bytes.count), SQLiteDatabase.transientDestructor)
                }
            }
            guard code == SQLITE_OK else { throw database.error(code) }
        }
    }

    /// Ends a statement early, so a transaction can commit or roll back.
    func reset() { sqlite3_reset(handle) }
    /// True for statements that cannot change the database.
    var isReadOnly: Bool { sqlite3_stmt_readonly(handle) != 0 }

    /// True when a row is available, false when the statement is finished.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw database.error(code)
    }

    var columnCount: Int { Int(sqlite3_column_count(handle)) }
    func columnName(_ index: Int) -> String {
        sqlite3_column_name(handle, Int32(index)).map { String(cString: $0) } ?? ""
    }
    func isNull(_ index: Int) -> Bool { sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL }
    func int(_ index: Int) -> Int { Int(sqlite3_column_int64(handle, Int32(index))) }
    func text(_ index: Int) -> String {
        sqlite3_column_text(handle, Int32(index)).map { String(cString: $0) } ?? ""
    }
    func blob(_ index: Int) -> Data {
        let count = Int(sqlite3_column_bytes(handle, Int32(index)))
        guard count > 0, let bytes = sqlite3_column_blob(handle, Int32(index)) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    func value(_ index: Int) -> SQLiteValue {
        switch sqlite3_column_type(handle, Int32(index)) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(handle, Int32(index)))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(handle, Int32(index)))
        case SQLITE_TEXT: return .text(text(index))
        case SQLITE_BLOB: return .blob(blob(index))
        default: return .null
        }
    }
}
