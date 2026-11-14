import Foundation

/// A chat's CSV file as a table the model's SQL can query.
public struct FileTable: Equatable, Sendable {
    /// The file it came from, e.g. `data/sales.csv`.
    public let path: String
    /// The table name: the file name without `.csv`, e.g. `sales`.
    public let name: String
    public let columns: [String]
    public let rows: [[String]]
}

/// Turns the chat's `.csv` files into tables for `run_sql`. Small models write
/// `SELECT … FROM sales.csv` on their own; this makes the data reachable
/// without copying it row by row through INSERT statements.
public enum FileTables {
    public static let maxTables = 8
    /// Text read across all files. Attachments are capped at 5 MB each, so this is the real limit.
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxColumns = 100

    /// Tables for the `.csv` files among `files`, in path order. A file whose
    /// name collides with an earlier table, or that has no header row, is skipped.
    public static func tables(from files: [(path: String, text: String)]) -> [FileTable] {
        var tables: [FileTable] = []
        var names = Set<String>()
        var bytes = 0
        for file in files.sorted(by: { $0.path < $1.path }) where file.path.lowercased().hasSuffix(".csv") {
            guard tables.count < maxTables else { break }
            bytes += file.text.utf8.count
            guard bytes <= maxBytes else { break }
            let name = tableName(for: file.path)
            guard !names.contains(name.lowercased()) else { continue }
            // The parser treats "\r\n" as one character, so line endings are normalised first.
            var rows = CSVParser.parse(text: file.text.replacingOccurrences(of: "\r\n", with: "\n"))
            guard !rows.isEmpty else { continue }
            let header = Array(rows.removeFirst().prefix(maxColumns))
            names.insert(name.lowercased())
            tables.append(FileTable(path: file.path, name: name, columns: columnNames(header), rows: rows))
        }
        return tables
    }

    /// `data/Sales 2026.csv` becomes `Sales_2026`. A name that would start with
    /// a digit gets a leading underscore. The table is reachable as `Sales_2026.csv` too.
    static func tableName(for path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let stem = file.count > 4 ? String(file.dropLast(4)) : "file"
        var name = String(stem.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
        })
        // `main` and `temp` are SQLite's own databases, so a file cannot take those names.
        if name.first?.isNumber ?? true || ["main", "temp"].contains(name.lowercased()) { name = "_" + name }
        return name
    }

    static func columnNames(_ header: [String]) -> [String] {
        var seen = Set<String>()
        return header.enumerated().map { index, raw in
            let base = raw.trimmingCharacters(in: .whitespaces).isEmpty ? "column_\(index + 1)" : raw.trimmingCharacters(in: .whitespaces)
            var name = base
            var suffix = 2
            while seen.contains(name.lowercased()) { name = "\(base)_\(suffix)"; suffix += 1 }
            seen.insert(name.lowercased())
            return name
        }
    }

    /// One line per table for the model: `sales.csv or sales: date, product, amount`.
    public static func summary(_ tables: [FileTable]) -> String {
        tables.map { "\($0.name).csv or \($0.name): \($0.columns.joined(separator: ", "))" }.joined(separator: "\n")
    }
}
