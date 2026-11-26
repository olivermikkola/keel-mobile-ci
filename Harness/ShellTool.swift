import Foundation

/// The `shell` tool: bash commands over the chat's own files.
///
/// Small models have seen millions of terminal sessions and few of Keel's own
/// tool names, so they reach for `ls`, `cat`, `grep` and `sed`. This tool takes
/// that command as written. There is no process: `Resources/KeelShell.js`
/// (just-bash, built by `tools/keel-shell`) interprets it inside ScriptRunner's
/// web view, the same sandbox as `run_js`, and the files it sees are the task
/// workspace through `keel.*`. Every file the command changes comes back as a
/// proposal the user reviews; nothing else is kept. There is no network command.
public enum ShellTool {
    public static let name = "shell"

    /// Tools a plain Work chat drops when it offers `shell`: `ls`, `rm` and `mv`
    /// are what models write anyway, deletes and moves still become reviewed
    /// proposals, and small models do better with fewer tools (the router's
    /// budget for them is 10). Apps keep their own tool sets.
    public static let replaces: Set<String> = ["list_files", "delete_file", "rename_file"]

    public static let schemaLine = #"{"type":"function","function":{"name":"shell","description":"Run a bash command in this chat's files, in the folder /workspace. Has ls, cat, head, tail, grep, find, sed, awk, jq, wc, sort, uniq, diff, cut, tr, xargs, mkdir, cp, mv, rm, touch, echo and printf with > and >>, pipes, && and for loops. No network, no python, no node, no package installs. Files you create or change are saved for the user to review; later commands see them. Each call starts fresh in /workspace. /tmp is scratch and is not kept.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}"#

    /// Longest command accepted, in UTF-8 bytes. A one-line command rarely
    /// passes 1 KB; a heredoc that writes a page can need more.
    public static let maxCommandBytes = 16 * 1_024
    /// stdout shown to the model, in UTF-8 bytes. The rest is cut with a note.
    public static let maxStdoutBytes = 6_000
    /// stderr shown to the model, in UTF-8 bytes.
    public static let maxStderrBytes = 2_000
    /// Wall-clock limit for one command, in seconds. Scripts in `run_js` get 5;
    /// a recursive grep over a few hundred files needs more host calls.
    public static let timeout: TimeInterval = 10

    /// Per-command limits. `run_js` reads a handful of files; a shell command
    /// such as `grep -rn` touches every file, one host call each.
    public static var budget: ScriptBudget {
        var budget = ScriptBudget()
        budget.maxHostCalls = 3_000
        budget.maxBytesRead = 4 * 1_024 * 1_024
        budget.maxBytesWrittenPerFile = 256 * 1_024
        budget.maxBytesWritten = 1_024 * 1_024
        budget.maxListedFiles = 5_000
        return budget
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    /// The command from a call's arguments, checked.
    public static func command(_ arguments: [String: String]) throws -> String {
        guard Set(arguments.keys) == ["command"], let raw = arguments["command"] else {
            throw Problem.invalid("Expected command, one bash command line.")
        }
        let command = DirectorCall.unwrapSingleKeyJSON(raw, key: "command")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Problem.invalid("The command is empty.")
        }
        guard command.utf8.count <= maxCommandBytes, !command.utf8.contains(0) else {
            throw Problem.invalid("The command is over \(maxCommandBytes / 1_024) KB. Write a large file in smaller steps.")
        }
        return command
    }

    /// The JavaScript that runs one command. The command goes in as a JSON
    /// string literal, so no quoting in it can break out of the call.
    public static func invocation(_ command: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        let literal = String(array.dropFirst().dropLast())
        return "return await globalThis.__keelShell(\(literal));"
    }

    /// What `__keelShell` returns.
    struct Reply: Decodable {
        let stdout: String
        let stderr: String
        let exitCode: Int
        let problems: [String]
    }

    /// Plain text for the model, laid out like a terminal: output, then
    /// stderr, the exit code when it is not 0, and the files saved for review.
    public static func format(_ outcome: ScriptOutcome, changedFiles: [String]) -> String {
        switch outcome {
        case .timedOut(let seconds):
            return "The command was stopped after \(seconds) s. Nothing was changed. Try a narrower command, for example limit grep to one folder."
        case .failed(let message):
            return "shell error: \(message)\nNothing was changed."
        case .finished(let value):
            guard let value, let reply = try? JSONDecoder().decode(Reply.self, from: Data(value.utf8)) else {
                return "shell error: the shell did not answer.\nNothing was changed."
            }
            var sections: [String] = []
            let stdout = clip(reply.stdout, to: maxStdoutBytes)
            if !stdout.isEmpty { sections.append(stdout) }
            let stderr = clip(reply.stderr, to: maxStderrBytes)
            if !stderr.isEmpty { sections.append("stderr:\n" + stderr) }
            if reply.exitCode != 0 { sections.append("exit code \(reply.exitCode)") }
            if !changedFiles.isEmpty {
                sections.append("Saved for review: " + changedFiles.joined(separator: ", "))
            }
            if !reply.problems.isEmpty {
                sections.append("Not saved:\n" + reply.problems.joined(separator: "\n"))
            }
            return sections.isEmpty ? "(no output)" : sections.joined(separator: "\n")
        }
    }

    /// What the model reads for each file a command changed. The usual
    /// proposal note says "summarize your proposal and stop", which would end a
    /// shell session after its first write; here the next command sees the file.
    public static func savedNote(kind: String, path: String) -> String {
        "Saved for review: \(kind) \(path). Later shell commands in this chat see the change; keep going until the task is done."
    }

    /// Cuts on a whole character and says how much was left out, so the model
    /// knows to narrow the command rather than assume it saw everything.
    static func clip(_ text: String, to limit: Int) -> String {
        var text = text
        while text.hasSuffix("\n") { text.removeLast() }
        let total = text.utf8.count
        guard total > limit else { return text }
        var kept = ""
        for character in text {
            guard kept.utf8.count + String(character).utf8.count <= limit else { break }
            kept.append(character)
        }
        return kept + "\n[output cut: \(total - kept.utf8.count) more bytes. Use head, tail or grep to see less at once.]"
    }
}
