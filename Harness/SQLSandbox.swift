import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Budgets for one sandbox. These are new limits, not ports of a desktop value.
public struct SQLLimits: Equatable, Sendable {
    /// Wall-clock seconds one `run` may take before it is interrupted.
    public var timeout: Double
    /// Rows shown from the last result set.
    public var maxRows: Int
    /// Bytes of header and rows shown from the last result set.
    public var maxOutputBytes: Int
    /// Size cap for the scratch database, rounded down to whole pages.
    public var maxDatabaseBytes: Int
    /// Largest single text or blob value a statement may build.
    public var maxValueBytes: Int

    public init(timeout: Double = 2, maxRows: Int = 50, maxOutputBytes: Int = 4_096, maxDatabaseBytes: Int = 4 * 1024 * 1024, maxValueBytes: Int = 1024 * 1024) {
        self.timeout = timeout
        self.maxRows = maxRows
        self.maxOutputBytes = maxOutputBytes
        self.maxDatabaseBytes = maxDatabaseBytes
        self.maxValueBytes = maxValueBytes
    }
}

/// What the model sees after one `run`.
public struct SQLResult: Equatable, Sendable {
    /// Header, rows and one-line summaries. Errors start with "Error:".
    public let text: String
    /// True when the SQL failed or was refused.
    public let isError: Bool
}

/// A scratch SQLite database the model's SQL runs in. It is separate from the
/// task workspace, and the SQL can reach no other file: ATTACH is refused,
/// only read-only PRAGMAs run, and a wall-clock timer and size caps stop
/// runaway work.
///
/// Each `run` is one transaction. If any statement fails, every change from
/// that call is rolled back.
public final class SQLSandbox: @unchecked Sendable {
    /// PRAGMAs the model may read. Every other PRAGMA is refused.
    static let readOnlyPragmas: Set<String> = ["table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo"]

    private let limits: SQLLimits
    private let database: SQLiteDatabase
    private let state = SandboxState()

    /// `path` is a file for persistent scratch data, or ":memory:" for a database that dies with the object.
    public init(path: String = ":memory:", limits: SQLLimits = SQLLimits()) throws {
        self.limits = limits
        database = try SQLiteDatabase(path: path)
        // Setup runs before the authorizer is installed, so these PRAGMAs are ours, not the model's.
        try database.execute("PRAGMA temp_store = MEMORY")
        let pageSize = try database.scalar("PRAGMA page_size").map { value -> Int in
            if case .integer(let number) = value { return Int(number) }
            return 4_096
        } ?? 4_096
        try database.execute("PRAGMA max_page_count = \(max(1, limits.maxDatabaseBytes / pageSize))")
        _ = sqlite3_limit(database.handle, SQLITE_LIMIT_ATTACHED, 0)
        // One value cannot outgrow the phone's memory: `zeroblob(1000000000)` fails instead of allocating.
        _ = sqlite3_limit(database.handle, SQLITE_LIMIT_LENGTH, Int32(limits.maxValueBytes))

        let context = Unmanaged.passUnretained(state).toOpaque()
        sqlite3_set_authorizer(database.handle, sandboxAuthorizer, context)
        sqlite3_progress_handler(database.handle, 1_000, sandboxProgress, context)
    }

    /// Runs one or more statements. Returns the last result set and the number of rows changed.
    public func run(_ sql: String) -> SQLResult {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SQLResult(text: "Error: no SQL to run.", isError: true)
        }
        state.deadline = Date().addingTimeInterval(limits.timeout)
        state.timedOut = false
        state.denied = nil
        do {
            return SQLResult(text: render(try execute(sql)), isError: false)
        } catch {
            return SQLResult(text: describe(error), isError: true)
        }
    }

    // MARK: - Execution

    private struct ResultSet {
        var columns: [String]
        var rows: [[String]] = []
        var truncated = false
    }

    private struct Outcome {
        var result: ResultSet?
        var changes = 0
    }

    private func execute(_ sql: String) throws -> Outcome {
        var outcome = Outcome()
        try control("BEGIN IMMEDIATE")
        do {
            let bytes = Array(sql.utf8CString)
            var offset = 0
            while offset < bytes.count - 1 {
                let (statement, next) = try database.prepare(bytes: bytes, offset: offset)
                guard next > offset else { break }
                offset = next
                guard let statement else { continue }
                let before = database.totalChanges
                try collect(statement, into: &outcome)
                outcome.changes += database.totalChanges - before
            }
            try control("COMMIT")
            return outcome
        } catch {
            // The timer may be what failed. Lift it so the rollback can finish.
            state.deadline = .distantFuture
            try? control("ROLLBACK")
            throw error
        }
    }

    /// Runs one fixed statement with the authorizer's transaction rule lifted.
    private func control(_ sql: String) throws {
        state.allowControl = true
        defer { state.allowControl = false }
        try database.execute(sql)
    }

    private func collect(_ statement: SQLiteStatement, into outcome: inout Outcome) throws {
        let hasColumns = statement.columnCount > 0
        var set = ResultSet(columns: hasColumns ? (0..<statement.columnCount).map(statement.columnName) : [])
        while try statement.step() {
            if set.rows.count < limits.maxRows {
                set.rows.append((0..<statement.columnCount).map { display(statement.value($0)) })
            } else {
                set.truncated = true
                // A read-only query can stop here. A write must run to the end.
                if statement.isReadOnly { break }
            }
        }
        statement.reset()
        if hasColumns { outcome.result = set }
    }

    private func display(_ value: SQLiteValue) -> String {
        switch value {
        case .null: return "NULL"
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .text(let text): return text.components(separatedBy: .newlines).joined(separator: "\\n")
        case .blob(let data): return "<blob \(data.count) bytes>"
        }
    }

    // MARK: - Output

    private func render(_ outcome: Outcome) -> String {
        var lines: [String] = []
        if let set = outcome.result {
            lines.append(set.columns.joined(separator: " | "))
            var bytes = 0
            var shown = 0
            var cutByBytes = false
            for row in set.rows {
                let line = row.joined(separator: " | ")
                if bytes + line.utf8.count > limits.maxOutputBytes { cutByBytes = true; break }
                bytes += line.utf8.count + 1
                lines.append(line)
                shown += 1
            }
            if cutByBytes {
                lines.append("truncated at \(limits.maxOutputBytes) bytes (showing \(count(shown, "row")))")
            } else if set.truncated {
                lines.append("truncated at \(limits.maxRows) rows")
            } else {
                lines.append(count(shown, "row"))
            }
        }
        if outcome.changes > 0 {
            lines.append("\(count(outcome.changes, "row")) changed")
        } else if outcome.result == nil {
            lines.append("OK")
        }
        return lines.joined(separator: "\n")
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private func describe(_ error: Error) -> String {
        if state.timedOut {
            return "Error: stopped after \(limits.timeout) s. Add a LIMIT or narrow the query. Nothing was changed."
        }
        if let denied = state.denied {
            return "Error: \(denied) Nothing was changed."
        }
        if let error = error as? SQLiteError {
            // SQLITE_FULL is the size cap, which is worth saying in plain words.
            if error.code & 0xff == SQLITE_FULL {
                return "Error: the scratch database reached its size limit of \(limits.maxDatabaseBytes / 1024) KB. Nothing was changed."
            }
            return "Error: \(error.message). Nothing was changed."
        }
        return "Error: \(error). Nothing was changed."
    }
}

/// State the C callbacks read. The SQLSandbox owns it, so it outlives them.
private final class SandboxState {
    var deadline = Date.distantFuture
    var timedOut = false
    var denied: String?
    var allowControl = false

    /// Refuses everything the scratch database must not do. Runs for each statement as it is prepared.
    func authorize(_ action: Int32, _ first: String, _ second: String) -> Int32 {
        var denial: String?
        switch action {
        case SQLITE_ATTACH: denial = "ATTACH is not allowed. The scratch database is the only one."
        case SQLITE_DETACH: denial = "DETACH is not allowed."
        case SQLITE_PRAGMA:
            if !SQLSandbox.readOnlyPragmas.contains(first.lowercased()) {
                denial = "PRAGMA \(first) is not allowed. Only table_info and index_* can be read."
            }
        case SQLITE_FUNCTION:
            if second.lowercased() == "load_extension" { denial = "load_extension is not allowed." }
        case SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
            if !allowControl { denial = "Transactions are managed for you. Remove BEGIN, COMMIT, ROLLBACK and SAVEPOINT." }
        case SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW,
             SQLITE_DROP_TEMP_INDEX, SQLITE_DROP_TEMP_TABLE, SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_TEMP_VIEW:
            denial = "Temporary tables and views are not allowed. Use CREATE TABLE."
        case SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE: denial = "Virtual tables are not allowed."
        default: break
        }
        guard let denial else { return SQLITE_OK }
        self.denied = denial
        return SQLITE_DENY
    }
}

/// C callbacks cannot capture, so they reach the state through the context pointer.
private let sandboxAuthorizer: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { context, action, first, second, _, _ in
    let state = Unmanaged<SandboxState>.fromOpaque(context!).takeUnretainedValue()
    return state.authorize(action, first.map { String(cString: $0) } ?? "", second.map { String(cString: $0) } ?? "")
}

/// Returns non-zero to stop the running statement once the deadline has passed.
private let sandboxProgress: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    let state = Unmanaged<SandboxState>.fromOpaque(context!).takeUnretainedValue()
    if Date() < state.deadline { return 0 }
    state.timedOut = true
    return 1
}
