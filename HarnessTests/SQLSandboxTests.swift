import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class SQLSandboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sql-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sandbox(_ limits: SQLLimits = SQLLimits()) throws -> SQLSandbox {
        try SQLSandbox(limits: limits)
    }

    // MARK: - Normal use

    func testCreateInsertSelectShowsHeaderRowsAndSummary() throws {
        let db = try sandbox()
        let created = db.run("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        XCTAssertFalse(created.isError)
        XCTAssertEqual(created.text, "OK")

        let inserted = db.run("INSERT INTO people (name) VALUES ('ann'), ('bob')")
        XCTAssertEqual(inserted.text, "2 rows changed")

        let selected = db.run("SELECT id, name FROM people ORDER BY id")
        XCTAssertFalse(selected.isError)
        XCTAssertEqual(selected.text, "id | name\n1 | ann\n2 | bob\n2 rows")
    }

    func testMultipleStatementsReportLastSelectAndTotalChanges() throws {
        let db = try sandbox()
        let result = db.run("CREATE TABLE n (x INTEGER); INSERT INTO n VALUES (1), (2), (3); SELECT count(*) AS total FROM n; ")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "total\n3\n1 row\n3 rows changed")
    }

    func testEmptySQLIsAnError() throws {
        let result = try sandbox().run("   ")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Error:"))
    }

    func testNullBlobAndNewlinesAreShownOnOneLine() throws {
        let result = try sandbox().run("SELECT NULL AS a, zeroblob(4) AS b, 'x' || char(10) || 'y' AS c")
        XCTAssertEqual(result.text, "a | b | c\nNULL | <blob 4 bytes> | x\\ny\n1 row")
    }

    // MARK: - Errors

    func testSyntaxErrorIsShortAndNamesSQLiteMessage() throws {
        let result = try sandbox().run("SELEC 1")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Error: "))
        XCTAssertTrue(result.text.contains("syntax error"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Nothing was changed."))
    }

    func testFailedCallRollsBackEarlierStatements() throws {
        let db = try sandbox()
        _ = db.run("CREATE TABLE keep (x INTEGER)")
        let failed = db.run("INSERT INTO keep VALUES (1); SELECT * FROM missing_table")
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("no such table"), failed.text)
        XCTAssertEqual(db.run("SELECT count(*) FROM keep").text, "count(*)\n0\n1 row")
    }

    // MARK: - Denied capabilities

    func testAttachIsDeniedAndCreatesNoFile() throws {
        let other = directory.appendingPathComponent("other.db").path
        let db = try sandbox()
        let result = db.run("ATTACH DATABASE '\(other)' AS other")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("ATTACH is not allowed"), result.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
    }

    func testVacuumIntoCannotWriteAFile() throws {
        let target = directory.appendingPathComponent("vacuumed.db").path
        let db = try sandbox()
        _ = db.run("CREATE TABLE t (x INTEGER)")
        _ = db.run("VACUUM INTO '\(target)'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testDetachIsDenied() throws {
        let result = try sandbox().run("DETACH DATABASE main")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("DETACH is not allowed"), result.text)
    }

    func testLoadExtensionIsDenied() throws {
        let result = try sandbox().run("SELECT load_extension('/tmp/evil.so')")
        XCTAssertTrue(result.isError)
        // Linux SQLite exposes load_extension and hits our authorizer; iOS SQLite omits the function at build time.
        XCTAssertTrue(result.text.contains("load_extension is not allowed") || result.text.contains("no such function: load_extension"), result.text)
    }

    func testDangerousPragmasAreDenied() throws {
        let db = try sandbox()
        for sql in ["PRAGMA writable_schema = ON", "PRAGMA journal_mode = DELETE", "PRAGMA max_page_count = 1000000", "PRAGMA temp_store = FILE"] {
            let result = db.run(sql)
            XCTAssertTrue(result.isError, sql)
            XCTAssertTrue(result.text.contains("is not allowed"), result.text)
        }
    }

    func testReadOnlyTableInfoPragmaStillWorks() throws {
        let db = try sandbox()
        _ = db.run("CREATE TABLE t (a INTEGER, b TEXT)")
        let result = db.run("PRAGMA table_info(t)")
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("b | TEXT") || result.text.contains("TEXT"), result.text)
    }

    func testTemporaryTablesAreDenied() throws {
        let result = try sandbox().run("CREATE TEMP TABLE scratch (x INTEGER)")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Temporary tables"), result.text)
    }

    func testModelCannotControlTransactions() throws {
        let db = try sandbox()
        let result = db.run("BEGIN; CREATE TABLE t (x INTEGER); COMMIT")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Transactions are managed"), result.text)
        // The sandbox's own transaction is still usable afterwards.
        XCTAssertFalse(db.run("CREATE TABLE t (x INTEGER)").isError)
    }

    // MARK: - Timeout

    func testRunawayRecursiveQueryIsInterrupted() throws {
        let db = try sandbox(SQLLimits(timeout: 0.3))
        let started = Date()
        let result = db.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("stopped after"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // The timed-out call is rolled back, and the next call works.
        XCTAssertEqual(db.run("SELECT 1 AS ok").text, "ok\n1\n1 row")
    }

    // MARK: - Output caps

    func testRowCapTruncatesAndStopsReadOnlyQuery() throws {
        let db = try sandbox(SQLLimits(maxRows: 50))
        let result = db.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasSuffix("truncated at 50 rows"), result.text)
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, 52)
    }

    func testByteCapTruncatesRows() throws {
        let db = try sandbox(SQLLimits(maxOutputBytes: 100))
        let result = db.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500) SELECT printf('%010d', x) AS v FROM c")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("truncated at 100 bytes"), result.text)
        XCTAssertLessThan(result.text.utf8.count, 200)
    }

    func testWriteCountsAllRowsWhenResultIsCapped() throws {
        let db = try sandbox(SQLLimits(maxRows: 2))
        let result = db.run("CREATE TABLE t (x INTEGER); WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10) INSERT INTO t SELECT x FROM c RETURNING x")
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(db.run("SELECT count(*) FROM t").text, "count(*)\n10\n1 row")
    }

    // MARK: - Size cap

    func testDatabaseSizeCapStopsGrowth() throws {
        let db = try sandbox(SQLLimits(maxDatabaseBytes: 16 * 1024))
        _ = db.run("CREATE TABLE big (x INTEGER, payload BLOB)")
        let result = db.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500) INSERT INTO big SELECT x, zeroblob(1000) FROM c")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("size limit of 16 KB"), result.text)
        XCTAssertEqual(db.run("SELECT count(*) FROM big").text, "count(*)\n0\n1 row")
    }

    // MARK: - Persistence

    func testFileBackedDatabasePersistsAcrossCallsAndObjects() throws {
        let path = directory.appendingPathComponent("scratch.sqlite").path
        let first = try SQLSandbox(path: path)
        XCTAssertFalse(first.run("CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('kept')").isError)
        XCTAssertEqual(first.run("SELECT body FROM notes").text, "body\nkept\n1 row")

        let second = try SQLSandbox(path: path)
        XCTAssertEqual(second.run("SELECT body FROM notes").text, "body\nkept\n1 row")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testOneHugeValueIsRefusedInsteadOfAllocated() throws {
        let sandbox = try SQLSandbox()
        let result = sandbox.run("SELECT length(zeroblob(1000000000))")
        XCTAssertTrue(result.isError, result.text)
        XCTAssertFalse(sandbox.run("SELECT length(zeroblob(1000))").isError)
    }
}
