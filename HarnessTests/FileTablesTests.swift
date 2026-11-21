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
        XCTAssertTrue(result.text.hasSuffix("The chat's tables are:\nsales.csv or sales: date, product, amount"), result.text)
    }

    func testSyntaxErrorOnHyphenatedCSVFilenameListsRealTableName() throws {
        let carLog = (path: "car-log.csv", text: "date,miles\n2026-11-01,42\n")
        let result = try SQLSandbox().run("SELECT * FROM car-log.csv", tables: FileTables.tables(from: [carLog]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("syntax error"), result.text)
        XCTAssertTrue(result.text.hasSuffix("The chat's tables are:\ncar_log.csv or car_log: date, miles"), result.text)
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

    // MARK: - The files table

    private func chat(_ files: [(path: String, text: String)]) throws -> TaskWorkspace {
        let workspace = try TaskWorkspace(path: ":memory:")
        try LocalFiles.prepare(workspace, key: "test", operations: files.map { .write(path: $0.path, text: $0.text) })
        return workspace
    }

    func testFilesTableListsEveryFileOfTheChat() throws {
        let workspace = try chat([sales, (path: "notes/trip.md", text: "Day 1\nDay 2\n"), (path: "notes/Packing.MD", text: "tent"),
                                  (path: "README", text: "")])
        let tables = FileTables.tables(for: workspace)
        XCTAssertEqual(tables.map(\.name), ["sales", "files"])
        let sandbox = try SQLSandbox()
        XCTAssertEqual(sandbox.run("SELECT path, folder, name, extension, bytes, lines, kind FROM files", tables: tables).text, """
            path | folder | name | extension | bytes | lines | kind
            README | . | README | NULL | 0 | 0 | text
            notes/Packing.MD | notes | Packing.MD | md | 4 | 1 | text
            notes/trip.md | notes | trip.md | md | 12 | 2 | text
            sales.csv | . | sales.csv | csv | 95 | 5 | text
            4 rows
            """)
        // What a small model asks first.
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM files WHERE extension = 'md'", tables: tables).text, "COUNT(*)\n2\n1 row")
        XCTAssertEqual(sandbox.run("SELECT folder, COUNT(*) AS n FROM files GROUP BY folder ORDER BY folder", tables: tables).text,
                       "folder | n\n. | 2\nnotes | 2\n2 rows")
        XCTAssertEqual(sandbox.run("SELECT name FROM files ORDER BY bytes DESC LIMIT 1", tables: tables).text, "name\nsales.csv\n1 row")
        // And a CSV file can still be read as rows next to it.
        XCTAssertEqual(sandbox.run("SELECT COUNT(*) FROM sales.csv", tables: tables).text, "COUNT(*)\n4\n1 row")
    }

    func testFilesTableIsReadOnlyAndFollowsTheFiles() throws {
        let workspace = try chat([(path: "a.md", text: "x\n")])
        let sandbox = try SQLSandbox()
        // The listing is a view of the files, not something SQL can change.
        XCTAssertEqual(sandbox.run("DELETE FROM files", tables: FileTables.tables(for: workspace)).text,
                       "Error: cannot modify files because it is a view. Nothing was changed.")
        // The next call lists the files as they are then.
        try LocalFiles.prepare(workspace, key: "test2", operations: [.write(path: "a.md", text: "x\n"), .write(path: "b.md", text: "y\n")])
        XCTAssertEqual(sandbox.run("SELECT path FROM files", tables: FileTables.tables(for: workspace)).text, "path\na.md\nb.md\n2 rows")
    }

    func testAChatsOwnFilesCSVKeepsTheName() throws {
        let workspace = try chat([(path: "files.csv", text: "title\nreport\n")])
        let tables = FileTables.tables(for: workspace)
        XCTAssertEqual(tables.map(\.name), ["files"])
        XCTAssertEqual(try SQLSandbox().run("SELECT * FROM files", tables: tables).text, "title\nreport\n1 row")
    }

    func testFilesTableWorksWithAFullSetOfCSVTables() throws {
        let workspace = try chat((0..<12).map { (path: "t\($0).csv", text: "x\n1\n") })
        let tables = FileTables.tables(for: workspace)
        XCTAssertEqual(tables.count, FileTables.maxTables + 1)
        XCTAssertEqual(try SQLSandbox().run("SELECT COUNT(*) FROM files", tables: tables).text, "COUNT(*)\n12\n1 row")
    }

    func testMissingTableErrorListsTheFilesTable() throws {
        let result = try SQLSandbox().run("SELECT * FROM folders", tables: FileTables.tables(for: try chat([sales])))
        XCTAssertTrue(result.text.hasSuffix("""
            The chat's tables are:
            sales.csv or sales: date, product, amount
            files (one row per file of this chat): path, folder, name, extension, bytes, lines, kind
            """), result.text)
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
