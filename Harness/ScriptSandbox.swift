import Foundation

// The capability sandbox between a task script and the task's files.
//
// The script runs in a JavaScript engine on the phone. Its only way out is
// `ScriptHost.handle`, which the WKWebView message handler calls with a host
// function name and JSON arguments. Every file touch goes through the
// TaskWorkspace API, never the file system, so the script cannot name the
// app's own files. There is no network function at all.

/// Per-run limits. Every default is a named constant here, so the numbers can
/// be compared with the desktop harness. None of these exist in desktop Keel
/// (it has a shell, which the phone does not), so the values are phone choices.
public struct ScriptBudget: Equatable, Sendable {
    /// Every host call counts, including failed ones and `print`.
    public var maxHostCalls = 200
    /// Text returned by `readFile` in one run, in UTF-8 bytes.
    public var maxBytesRead = 512 * 1_024
    /// Text written to one path in one run, in UTF-8 bytes (cumulative per path).
    public var maxBytesWrittenPerFile = 64 * 1_024
    /// Text written in one run across all paths, in UTF-8 bytes.
    public var maxBytesWritten = 256 * 1_024
    /// Captured `print` / `console.log` output, in UTF-8 bytes.
    public var maxPrintBytes = 8 * 1_024
    /// Files one `listFiles` call may return. More is an error, not a cut-off list.
    public var maxListedFiles = 500
    public init() {}
}

/// A failure the script can see. The message is plain text for the script and,
/// through the formatter, for the small model.
struct ScriptFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The reply envelope is `{"result": ...}` or `{"error": "..."}`. The prelude
/// turns an `error` reply into a thrown JavaScript Error.
public final class ScriptHost {
    /// Same bounds as RepositoryCall's path rules: 1024 bytes, 16 components.
    static let maxPathBytes = 1_024
    static let maxPathComponents = 16
    static let encodingFailure = #"{"error":"The reply could not be encoded."}"#

    public let budget: ScriptBudget
    let workspace: TaskWorkspace

    private(set) public var hostCalls = 0
    private(set) public var bytesRead = 0
    private(set) public var bytesWritten = 0
    /// Captured print output, each `print` followed by a newline. Cut at the
    /// print budget with a note.
    private(set) public var output = ""
    private(set) public var outputTruncated = false
    /// Every change the script made, in order. The caller saves these with the
    /// task's applied edits so they survive a rebuild of the overlay.
    private(set) public var operations: [TaskWorkspace.Operation] = []

    private var bytesWrittenByPath: [Data: Int] = [:]

    public init(workspace: TaskWorkspace, budget: ScriptBudget = ScriptBudget()) {
        self.workspace = workspace
        self.budget = budget
    }

    /// Paths the script changed, in the order it first changed them.
    public var changedFiles: [String] {
        var seen = Set<Data>()
        var result: [String] = []
        for operation in operations {
            let path: String
            switch operation {
            case .write(let name, _), .delete(let name): path = name
            }
            if seen.insert(Data(path.utf8)).inserted { result.append(path) }
        }
        return result
    }

    /// The single entry point for the WKWebView message handler. Never throws
    /// and never traps: every failure comes back as an `error` reply.
    public func handle(name: String, argumentsJSON: String) -> String {
        hostCalls += 1
        guard hostCalls <= budget.maxHostCalls else {
            return Self.reply(error: "Host call limit reached: \(budget.maxHostCalls) calls per run.")
        }
        guard let arguments = Self.parseArguments(argumentsJSON) else {
            return Self.reply(error: "Arguments must be one JSON object.")
        }
        do {
            switch name {
            case "readFile": return Self.reply(result: try readFile(arguments))
            case "writeFile": try writeFile(arguments); return Self.reply(result: NSNull())
            case "listFiles": return Self.reply(result: try listFiles(arguments))
            case "deleteFile": try deleteFile(arguments); return Self.reply(result: NSNull())
            case "print": try printText(arguments); return Self.reply(result: NSNull())
            default: return Self.reply(error: "Unknown host function: \(name).")
            }
        } catch let failure as ScriptFailure {
            return Self.reply(error: failure.message)
        } catch {
            return Self.reply(error: "The host call failed.")
        }
    }

    // MARK: - Host functions

    private func readFile(_ arguments: [String: Any]) throws -> String {
        let path = try Self.checkedPath(try Self.text(arguments, "path"))
        let file: TaskWorkspace.File
        do { file = try workspace.read(path) } catch { throw Self.failure(error, path) }
        let size = file.text.utf8.count
        guard bytesRead + size <= budget.maxBytesRead else {
            throw ScriptFailure("Read budget is used up: \(budget.maxBytesRead) bytes per run.")
        }
        bytesRead += size
        return file.text
    }

    private func writeFile(_ arguments: [String: Any]) throws {
        let path = try Self.checkedPath(try Self.text(arguments, "path"))
        let body = try Self.text(arguments, "text")
        let size = body.utf8.count
        let key = Data(path.utf8)
        guard (bytesWrittenByPath[key] ?? 0) + size <= budget.maxBytesWrittenPerFile else {
            throw ScriptFailure("This file is over its write budget: \(budget.maxBytesWrittenPerFile) bytes per file per run. Nothing was written.")
        }
        guard bytesWritten + size <= budget.maxBytesWritten else {
            throw ScriptFailure("Write budget is used up: \(budget.maxBytesWritten) bytes per run. Nothing was written.")
        }
        let operation = TaskWorkspace.Operation.write(path: path, text: body)
        do { try workspace.applyOverlay(operation) } catch { throw Self.failure(error, path) }
        bytesWritten += size
        bytesWrittenByPath[key, default: 0] += size
        operations.append(operation)
    }

    private func deleteFile(_ arguments: [String: Any]) throws {
        let path = try Self.checkedPath(try Self.text(arguments, "path"))
        let operation = TaskWorkspace.Operation.delete(path: path)
        do { try workspace.applyOverlay(operation) } catch { throw Self.failure(error, path) }
        operations.append(operation)
    }

    /// Every file whose path starts with `prefix`, in byte order. Walks only the
    /// folders that can lead to a match, through the same `list` the file
    /// browser uses.
    private func listFiles(_ arguments: [String: Any]) throws -> [String] {
        let prefix = try Self.optionalPrefix(arguments)
        let prefixBytes = Array(prefix.utf8)
        // Everything before the last "/" is the folder to start from.
        let parts = gitPathComponents(prefix)
        let start = parts.dropLast().joined(separator: "/")
        var found: [String] = []
        var folders = [start]
        while let folder = folders.popLast() {
            let children: [TaskWorkspace.Child]
            do {
                children = try workspace.list(folder)
            } catch WorkspaceError.missing, WorkspaceError.notDirectory {
                // Only the starting folder can be absent: the rest came from a listing.
                continue
            } catch {
                throw Self.failure(error, folder)
            }
            for child in children {
                let full = folder.isEmpty ? child.name : folder + "/" + child.name
                let marked = child.kind == .directory ? full + "/" : full
                // Keep only folders that can lead to a match.
                guard Array(marked.utf8).starts(with: prefixBytes) || prefixBytes.starts(with: Array(marked.utf8)) else { continue }
                if child.kind == .directory {
                    folders.append(full)
                } else if Array(full.utf8).starts(with: prefixBytes) {
                    found.append(full)
                }
            }
        }
        guard found.count <= budget.maxListedFiles else {
            throw ScriptFailure("More than \(budget.maxListedFiles) files match \"\(prefix)\". Use a longer prefix.")
        }
        return found.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
    }

    private func printText(_ arguments: [String: Any]) throws {
        let text = try Self.text(arguments, "text") + "\n"
        guard !outputTruncated else { return }
        let room = budget.maxPrintBytes - output.utf8.count
        if text.utf8.count <= room {
            output += text
            return
        }
        // Cut on a whole character so the captured text stays valid UTF-8.
        var kept = ""
        for character in text {
            guard kept.utf8.count + String(character).utf8.count <= room else { break }
            kept.append(character)
        }
        output += kept + "[output truncated at \(budget.maxPrintBytes) bytes]\n"
        outputTruncated = true
    }

    // MARK: - Arguments and paths

    static func parseArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    static func text(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String else {
            throw ScriptFailure("Argument \"\(key)\" must be text.")
        }
        return value
    }

    /// A path inside the task. Uses the workspace's own rule, plus the length
    /// and control-character limits of RepositoryCall, so both stay in step.
    static func checkedPath(_ path: String) throws -> String {
        guard path.utf8.count <= maxPathBytes,
              gitPathComponents(path).count <= maxPathComponents,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              TaskWorkspace.validPath(path) else {
            throw ScriptFailure("Use a relative path inside the task, such as Sources/App.swift.")
        }
        return path
    }

    /// A `listFiles` prefix: a path, or a path that ends in "/" or part of a
    /// name. Empty means the whole task.
    static func optionalPrefix(_ arguments: [String: Any]) throws -> String {
        guard arguments["prefix"] != nil else { return "" }
        let prefix = try text(arguments, "prefix")
        if prefix.isEmpty { return "" }
        // "/" alone is an absolute path, so the base left after dropping the slash must still be checked.
        let base = prefix.utf8.last == 47 ? String(decoding: prefix.utf8.dropLast(), as: UTF8.self) : prefix
        _ = try checkedPath(base)
        return prefix
    }

    static func failure(_ error: Error, _ path: String) -> ScriptFailure {
        guard let error = error as? WorkspaceError else { return ScriptFailure("The host call failed.") }
        switch error {
        case .path: return ScriptFailure("Use a relative path inside the task, such as Sources/App.swift.")
        case .missing: return ScriptFailure("No file at \"\(path)\" in this task.")
        case .isDirectory: return ScriptFailure("\"\(path)\" is a folder, not a file.")
        case .notDirectory: return ScriptFailure("A parent of \"\(path)\" is a file, not a folder.")
        case .notText: return ScriptFailure("\"\(path)\" is not UTF-8 text up to 256 KB.")
        case .notDownloaded: return ScriptFailure("\"\(path)\" is not downloaded yet.")
        case .tooLarge: return ScriptFailure("The task is too large for this change.")
        case .listing: return ScriptFailure("The task file list is malformed.")
        }
    }

    // MARK: - Replies

    static func reply(result: Any) -> String {
        encode(["result": result])
    }

    static func reply(error: String) -> String {
        encode(["error": error])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return encodingFailure
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// How the script ended, as the engine reports it.
public enum ScriptOutcome: Equatable, Sendable {
    /// Finished. `value` is the returned value as text, if any.
    case finished(value: String?)
    /// Threw. `message` is the script's error text.
    case failed(message: String)
    /// Stopped by the engine's hard timeout, in whole seconds.
    case timedOut(seconds: Int)
}

/// Plain text for a small model: captured output, the returned value, a list
/// of changed files, or one short error line.
public enum ScriptResultFormatter {
    /// Returned values are cut to this many UTF-8 bytes.
    static let maxValueBytes = 1_024
    /// The changed-file list names this many files, then says how many more.
    static let maxNamedFiles = 20

    public static func format(_ outcome: ScriptOutcome, output: String, changedFiles: [String]) -> String {
        var sections: [String] = []
        var text = output
        while text.hasSuffix("\n") { text.removeLast() }
        if !text.isEmpty { sections.append("Output:\n" + text) }
        switch outcome {
        case .finished(let value):
            if let value, !value.isEmpty { sections.append("Returned: " + clip(value)) }
        case .failed(let message):
            sections.append("script error: " + message)
        case .timedOut(let seconds):
            sections.append("timed out after \(seconds) s")
        }
        if !changedFiles.isEmpty {
            var line = "Files changed: " + changedFiles.prefix(maxNamedFiles).joined(separator: ", ")
            if changedFiles.count > maxNamedFiles { line += " and \(changedFiles.count - maxNamedFiles) more" }
            sections.append(line)
        }
        if sections.isEmpty, case .finished = outcome { return "Script finished with no output." }
        return sections.joined(separator: "\n")
    }

    private static func clip(_ value: String) -> String {
        guard value.utf8.count > maxValueBytes else { return value }
        var kept = ""
        for character in value {
            guard kept.utf8.count + String(character).utf8.count <= maxValueBytes else { break }
            kept.append(character)
        }
        return kept + " [value truncated]"
    }
}

/// The JavaScript that runs before the task script. It exposes the four file
/// functions and `console.log`, all through `__keelHost(name, argsJSON)`, and
/// hides the network entry points.
public enum ScriptPrelude {
    public static func source() -> String {
        """
        (function () {
          function call(name, args) {
            const reply = JSON.parse(__keelHost(name, JSON.stringify(args)));
            if (reply.error !== undefined) throw new Error(reply.error);
            return reply.result;
          }
          globalThis.keel = {
            readFile: (path) => call("readFile", { path: path }),
            writeFile: (path, text) => call("writeFile", { path: path, text: String(text) }),
            listFiles: (prefix) => call("listFiles", { prefix: prefix === undefined ? "" : String(prefix) }),
            deleteFile: (path) => call("deleteFile", { path: path })
          };
          const text = (value) => typeof value === "string" ? value : JSON.stringify(value);
          console.log = (...values) => { __keelHost("print", JSON.stringify({ text: values.map(text).join(" ") })); };
          ["fetch", "XMLHttpRequest", "WebSocket", "importScripts"].forEach((name) => {
            try { Object.defineProperty(globalThis, name, { value: undefined, writable: false, configurable: false }); } catch (error) { }
          });
        })();
        """
    }
}
