import Foundation

/// A chat's CSV file as a table the model's SQL can query.
public struct FileTable: Equatable, Sendable {
    /// The file it came from, e.g. `data/sales.csv`.
    public let path: String
    /// The table name: the file name without `.csv`, e.g. `sales`.
    public let name: String
    public let columns: [String]
    public let rows: [[String]]
    /// True for the `files` table that lists the chat's files, not a `.csv` file's rows.
    public var isListing = false
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
            // Strip a UTF-8 BOM (common in Excel/Numbers exports) so the first column
            // name matches SQL queries, and normalise CRLF/CR line endings before parsing.
            let withoutBOM = file.text.hasPrefix("\u{FEFF}") ? String(file.text.dropFirst()) : file.text
            let normalised = withoutBOM.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            var rows = CSVParser.parse(text: normalised)
            guard !rows.isEmpty else { continue }
            let header = Array(rows.removeFirst().prefix(maxColumns))
            names.insert(name.lowercased())
            tables.append(FileTable(path: file.path, name: name, columns: columnNames(header), rows: rows))
        }
        return tables
    }

    /// The CSV tables plus the `files` table: one row per file of the chat.
    /// A chat's own `files.csv` keeps the name, and the listing is left out.
    public static func tables(for workspace: TaskWorkspace) -> [FileTable] {
        let tables = tables(from: workspace.textFiles())
        guard !tables.contains(where: { $0.name.lowercased() == listingName }) else { return tables }
        return tables + [listing(workspace.fileEntries())]
    }

    public static let listingName = "files"
    public static let listingColumns = ["path", "folder", "name", "extension", "bytes", "lines", "kind"]
    /// Rows the listing holds at most; a chat with more files lists the first ones by path.
    public static let maxListingRows = 5_000

    /// `files`: path, folder (`.` at the top), name, extension (lowercase, no
    /// dot, NULL when none), bytes, lines (NULL unless text) and kind: `text`,
    /// `binary` for a file Keel cannot read as text, `pending` for one not
    /// downloaded yet.
    static func listing(_ entries: [TaskWorkspace.FileEntry]) -> FileTable {
        let rows = entries.sorted { $0.path < $1.path }.prefix(maxListingRows).map { entry -> [String] in
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            let name = parts.last.map(String.init) ?? entry.path
            let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : "."
            let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
            let ext = dot.map { String(name[name.index(after: $0)...]).lowercased() } ?? ""
            return [entry.path, folder, name, ext, String(entry.bytes), entry.lines.map(String.init) ?? "", entry.kind]
        }
        return FileTable(path: "", name: listingName, columns: listingColumns, rows: Array(rows), isListing: true)
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
        tables.map { table in
            table.isListing
                ? "\(table.name) (one row per file of this chat): \(table.columns.joined(separator: ", "))"
                : "\(table.name).csv or \(table.name): \(table.columns.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}
