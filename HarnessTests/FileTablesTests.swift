import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class FileTablesTests: XCTestCase {
    let sales = (path: "sales.csv", text: "date,product,amount\n2026-11-01,Tea,12\n2026-11-01,Coffee,30\n2026-11-02,Tea,40\n2026-11-03,Cocoa,\n")

    func testOnlyCSVFilesBecomeTablesNamedAfterTheFile() {
        let tables = FileTables.tables(from: [sales, (path: "notes.md", text: "a,b\n1,2\n"), (path: "data/2026 Q1.CSV", text: "x\r\n1\r\n2\r\n")])
        XCTAssertEqual(tables.map(\.name), ["_2026_Q1", "sales"])
        XCTAssertEqual(tables[0].rows, [["1"], ["2"]])
        XCTAssertEqual(tables[1].columns, ["date", "product", "amount"])
        XCTAssertEqual(tables[1].rows.count, 4)
        XCTAssertEqual(FileTables.summary([tables[1]]), "sales.csv or sales: date, product, amount")
        XCTAssertEqual(FileTables.tableName(for: "Main.csv"), "_Main")
    }

    func testColumnNamesAreFilledAndMadeUnique() {
        XCTAssertEqual(FileTables.columnNames(["a", "", "A", "a"]), ["a", "column_2", "A_2", "a_3"])
    }

    func testCollidingNamesAndLimitsSkipFiles() {
        let tables = FileTables.tables(from: [(path: "a/sales.csv", text: "x\n1\n"), (path: "b/sales.csv", text: "y\n2\n"), (path: "empty.csv", text: "")])
        XCTAssertEqual(tables.map(\.path), ["a/sales.csv"])
        let many = (0..<12).map { (path: "t\($0).csv", text: "x\n1\n") }
        XCTAssertEqual(FileTables.tables(from: many).count, FileTables.maxTables)
        let big = (path: "big.csv", text: "x\n" + String(repeating: "1\n", count: FileTables.maxBytes))
        XCTAssertTrue(FileTables.tables(from: [big]).isEmpty)
    }

    func testSQLQueriesFileTablesWithTypedValues() throws {
        let sandbox = try SQLSandbox()
        let tables = FileTables.tables(from: [sales])
        let result = sandbox.run("SELECT product, SUM(amount) AS total FROM sales GROUP BY product ORDER BY total DESC LIMIT 1", tables: tables)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "product | total\nTea | 52\n1 row")
        // An empty cell is NULL, and numbers compare as numbers.
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM sales WHERE amount IS NULL", tables: tables).text, "COUNT(*)\n1\n1 row")
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM sales WHERE amount > 9", tables: tables).text, "COUNT(*)\n3\n1 row")
    }

    func testFileTablesAreNotSavedAndReloadEachCall() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("filetables-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tables = FileTables.tables(from: [sales])
        XCTAssertEqual(try SQLSandbox(path: path).run("DELETE FROM sales.csv", tables: tables).text, "4 rows changed")
        // A new connection (the next call) sees the file's rows again, and nothing reached the scratch file.
        XCTAssertEqual(try SQLSandbox(path: path).run("SELECT COUNT(*) FROM sales", tables: tables).text, "COUNT(*)\n4\n1 row")
        XCTAssertTrue(try SQLSandbox(path: path).run("SELECT COUNT(*) FROM sales").isError)
        // The same sandbox can be reused after an earlier call set its timer.
        let sandbox = try SQLSandbox(path: path)
        _ = sandbox.run("SELECT 1")
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM sales", tables: tables).text, "COUNT(*)\n4\n1 row")
    }

    func testFileNameWorksAsTheTableName() throws {
        // What small models write first, seen in every eval sample that used run_sql.
        let result = try SQLSandbox().run("SELECT product, SUM(amount) AS total FROM sales.csv GROUP BY product ORDER BY total DESC LIMIT 1",
                                          tables: FileTables.tables(from: [sales]))
        XCTAssertEqual(result.text, "product | total\nTea | 52\n1 row")
    }

    func testMissingTableErrorNamesTheFileTables() throws {
        let result = try SQLSandbox().run("SELECT * FROM orders", tables: FileTables.tables(from: [sales]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasSuffix("The chat's CSV files are these tables:\nsales.csv or sales: date, product, amount"), result.text)
    }

    func testReloadingInOneSandboxFollowsTheFiles() throws {
        let sandbox = try SQLSandbox()
        XCTAssertFalse(sandbox.run("SELECT * FROM sales", tables: FileTables.tables(from: [sales])).isError)
        let renamed = FileTables.tables(from: [(path: "orders.csv", text: "id\n1\n")])
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM orders.csv", tables: renamed).text, "COUNT(*)\n1\n1 row")
        // The file that is gone is gone from SQL too.
        XCTAssertTrue(sandbox.run("SELECT * FROM sales", tables: renamed).isError)
        XCTAssertTrue(sandbox.run("SELECT * FROM sales.csv", tables: renamed).isError)
    }

    func testModelSQLStillCannotMakeTemporaryTables() throws {
        let sandbox = try SQLSandbox()
        let tables = FileTables.tables(from: [sales])
        XCTAssertTrue(sandbox.run("CREATE TEMP TABLE t(x)", tables: tables).text.contains("Temporary tables and views are not allowed"))
        XCTAssertTrue(sandbox.run("ATTACH ':memory:' AS other", tables: tables).text.contains("ATTACH is not allowed"))
        XCTAssertTrue(sandbox.run("DETACH sales", tables: tables).text.contains("DETACH is not allowed"))
        XCTAssertTrue(sandbox.run("SELECT 1").text.hasPrefix("1"))
        XCTAssertTrue(sandbox.run("ATTACH ':memory:' AS other").text.contains("ATTACH is not allowed"))
    }

    func testHeaderNamesCannotBreakOutOfTheirQuotes() throws {
        let tricky = (path: "t.csv", text: "\"a\"\"); DROP TABLE x; --\",b\n1,2\n")
        let sandbox = try SQLSandbox()
        XCTAssertFalse(sandbox.run("CREATE TABLE x(y)").isError)
        let result = sandbox.run("SELECT * FROM t", tables: FileTables.tables(from: [tricky]))
        XCTAssertEqual(result.text, "a\"); DROP TABLE x; -- | b\n1 | 2\n1 row")
        XCTAssertFalse(sandbox.run("SELECT * FROM x").isError)
    }

    func testLocalPromptTellsTheModelAboutFileTables() {
        let prompt = AgentPrompt.local()
        XCTAssertTrue(prompt.contains("Each .csv file of this chat is also a table: SELECT * FROM sales.csv reads sales.csv"))
        XCTAssertFalse(prompt.contains("repository files"))
    }
}
