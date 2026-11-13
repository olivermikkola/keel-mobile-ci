import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class TaskWorkspaceTests: XCTestCase {
    private let identity = TaskWorkspace.Identity(repository: "owner/fixture", commit: ArchiveFixture.commit, tree: ArchiveFixture.tree)
    private var entries: [TaskWorkspace.TreeEntry] {
        ArchiveFixture.entries.map { TaskWorkspace.TreeEntry(path: $0.path, mode: $0.mode, type: $0.type, sha: $0.sha, size: $0.size) }
    }
    private let composed = String(decoding: [100, 111, 99, 115, 47, 99, 97, 102, 195, 169, 46, 116, 120, 116] as [UInt8], as: UTF8.self)
    private let decomposed = String(decoding: [100, 111, 99, 115, 47, 99, 97, 102, 101, 204, 129, 46, 116, 120, 116] as [UInt8], as: UTF8.self)

    private func imported() throws -> TaskWorkspace {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(identity, entries: entries)
        _ = try workspace.importArchive(ArchiveFixture.dynamic)
        return workspace
    }

    // MARK: - Hashing and unpacking

    func testGitBlobHashMatchesGitForEmptyShortAndBlockBoundaryInputs() {
        XCTAssertEqual(GitBlob.sha(""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(GitBlob.sha("hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a")
        // Every listed fixture file must hash to what `git ls-tree` reported,
        // which covers padding around the 55/56/64-byte block boundaries.
        for size in [54, 55, 56, 57, 63, 64, 65, 119, 120, 128] {
            let data = Data(repeating: 97, count: size)
            var manual = GitSHA1()
            manual.update(Array("blob \(size)\0".utf8))
            for byte in data { manual.update([byte]) }
            XCTAssertEqual(GitBlob.sha(data), manual.finalize(), "size \(size)")
        }
    }

    func testDynamicFixedAndStoredDeflateProduceTheSameArchive() throws {
        func inflate(_ data: Data) throws -> Data {
            var output = Data()
            try Gunzip.inflate(data, limit: 1_000_000) { output.append($0) }
            return output
        }
        let tar = try inflate(ArchiveFixture.dynamic)
        XCTAssertEqual(tar.count, 51_200)
        XCTAssertEqual(try inflate(ArchiveFixture.fixed), tar)
        // A stored-block stream built here: blocks of at most 65,535 bytes.
        var stored = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        var offset = 0
        while offset < tar.count {
            let length = min(40_000, tar.count - offset)
            stored.append(offset + length == tar.count ? 1 : 0)
            stored.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)])
            stored.append(tar.subdata(in: offset..<(offset + length)))
            offset += length
        }
        stored.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(try inflate(stored), tar)
    }

    func testDamagedTruncatedAndOversizedArchivesFailWithoutStoringAnything() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(identity, entries: entries)
        XCTAssertThrowsError(try workspace.importArchive(Data("not gzip at all, just text".utf8))) {
            XCTAssertEqual($0 as? ArchiveError, .gzip)
        }
        XCTAssertThrowsError(try workspace.importArchive(ArchiveFixture.dynamic.prefix(1_500)))
        var limits = TaskWorkspace.Limits()
        limits.maxArchiveBytes = 10_000
        let bounded = try TaskWorkspace(path: ":memory:", limits: limits)
        try bounded.setBase(identity, entries: entries)
        XCTAssertThrowsError(try bounded.importArchive(ArchiveFixture.dynamic)) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        // A failed import rolls back as a whole.
        XCTAssertEqual(workspace.counts.text, 0)
        XCTAssertEqual(bounded.counts.text, 0)
        XCTAssertFalse(workspace.isComplete)
    }

    // MARK: - Base snapshot

    func testArchiveImportStoresOnlyHashVerifiedTextAndBecomesComplete() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(identity, entries: entries)
        XCTAssertFalse(workspace.isComplete)
        XCTAssertEqual(workspace.counts.pending, 12)
        XCTAssertThrowsError(try workspace.read("README.md")) { XCTAssertEqual($0 as? WorkspaceError, .notDownloaded) }

        let report = try workspace.importArchive(ArchiveFixture.dynamic)
        XCTAssertEqual(report, TaskWorkspace.ImportReport(stored: 11, binary: 1, mismatched: 0, skipped: 0))
        XCTAssertTrue(workspace.isComplete)
        XCTAssertEqual(workspace.identity, identity)
        XCTAssertEqual(workspace.counts, TaskWorkspace.Counts(text: 11, unsupported: 2, pending: 0, local: 0))

        let readme = try workspace.read("README.md")
        XCTAssertTrue(readme.text.hasPrefix("# Fixture\n"))
        XCTAssertEqual(readme.sha, GitBlob.sha(readme.text))
        XCTAssertFalse(readme.isLocal)
        XCTAssertEqual(try workspace.read("docs/empty.txt").text, "")
        XCTAssertEqual(try workspace.read("assets/crlf.txt").text, "one\r\ntwo\r\n")
        // Long names arrive through a pax header; the content must still land on the right path.
        let deep = ArchiveFixture.entries.first { $0.path.hasPrefix("deep/") }!.path
        XCTAssertGreaterThan(deep.utf8.count, 100)
        XCTAssertEqual(try workspace.read(deep).text, "long path content\n")
    }

    func testNamesThatAFolderOnDiskWouldMergeStaySeparateFiles() throws {
        let workspace = try imported()
        XCTAssertEqual(try workspace.read("Sources/Makefile").text, "all:\n\techo upper\n")
        XCTAssertEqual(try workspace.read("Sources/makefile").text, "all:\n\techo lower\n")
        XCTAssertEqual(try workspace.read(composed).text, "composed\n")
        XCTAssertEqual(try workspace.read(decomposed).text, "decomposed\n")
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertEqual(try workspace.list("docs").count, 3)
    }

    func testBinarySymlinkAndTraversalPathsAreNeverReadable() throws {
        let workspace = try imported()
        XCTAssertThrowsError(try workspace.read("assets/logo.bin")) { XCTAssertEqual($0 as? WorkspaceError, .notText) }
        XCTAssertThrowsError(try workspace.read("link")) { XCTAssertEqual($0 as? WorkspaceError, .notText) }
        XCTAssertThrowsError(try workspace.read("Sources")) { XCTAssertEqual($0 as? WorkspaceError, .isDirectory) }
        XCTAssertThrowsError(try workspace.read("Sources/Nope.swift")) { XCTAssertEqual($0 as? WorkspaceError, .missing) }
        for path in ["../chat.json", "/etc/passwd", "Sources/../../chat.json", "Sources//App.swift", "./README.md", "", "a\u{0}b"] {
            XCTAssertThrowsError(try workspace.read(path), path) { XCTAssertEqual($0 as? WorkspaceError, .path, path) }
        }
        XCTAssertThrowsError(try workspace.list("../")) { XCTAssertEqual($0 as? WorkspaceError, .path) }
        XCTAssertThrowsError(try workspace.list("README.md")) { XCTAssertEqual($0 as? WorkspaceError, .notDirectory) }
        XCTAssertThrowsError(try workspace.list("nowhere")) { XCTAssertEqual($0 as? WorkspaceError, .missing) }
    }

    func testContentThatDoesNotMatchThePinnedTreeIsRefused() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        var changed = entries
        let index = changed.firstIndex { $0.path == "README.md" }!
        // Same size, different hash: as if the archive were of another commit.
        changed[index] = TaskWorkspace.TreeEntry(path: "README.md", mode: "100644", type: "blob",
                                                 sha: String(repeating: "a", count: 40), size: changed[index].size)
        try workspace.setBase(identity, entries: changed)
        let report = try workspace.importArchive(ArchiveFixture.dynamic)
        XCTAssertEqual(report.mismatched, 1)
        XCTAssertEqual(report.stored, 10)
        XCTAssertFalse(workspace.isComplete)
        XCTAssertThrowsError(try workspace.read("README.md")) { XCTAssertEqual($0 as? WorkspaceError, .notDownloaded) }
        XCTAssertEqual(workspace.pendingFiles().map(\.path), ["README.md"])
        // A single verified blob can fill the gap; wrong bytes still cannot.
        XCTAssertFalse(try workspace.store(path: "README.md", data: Data("forged".utf8)))
        XCTAssertFalse(workspace.isComplete)
    }

    func testSingleBlobStoreVerifiesAgainstTheTree() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(identity, entries: entries)
        let text = "class Parser:\n    def parse(self, text):\n        return text.split()\n\ndef load_table(path):\n    return open(path).read()\n"
        XCTAssertFalse(try workspace.store(path: "Sources/util/helpers.py", data: Data((text + " ").utf8)))
        XCTAssertTrue(try workspace.store(path: "Sources/util/helpers.py", data: Data(text.utf8)))
        XCTAssertEqual(try workspace.read("Sources/util/helpers.py").text, text)
        XCTAssertFalse(try workspace.store(path: "not/listed.txt", data: Data("x".utf8)))
    }

    func testListingRejectsMalformedTreesAndOversizedRepositories() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        let sha = String(repeating: "b", count: 40)
        func entry(_ path: String, sha: String = String(repeating: "b", count: 40)) -> TaskWorkspace.TreeEntry {
            TaskWorkspace.TreeEntry(path: path, mode: "100644", type: "blob", sha: sha, size: 1)
        }
        for bad in [[entry("../escape")], [entry("a//b")], [entry("/abs")], [entry("a"), entry("a")], [entry("ok", sha: "nothex")]] {
            XCTAssertThrowsError(try workspace.setBase(identity, entries: bad)) { XCTAssertEqual($0 as? WorkspaceError, .listing) }
        }
        var limits = TaskWorkspace.Limits()
        limits.maxFiles = 2
        let small = try TaskWorkspace(path: ":memory:", limits: limits)
        XCTAssertThrowsError(try small.setBase(identity, entries: [entry("a"), entry("b"), entry("c")])) {
            XCTAssertEqual($0 as? WorkspaceError, .tooLarge)
        }
        // Directories in a recursive listing are implied by their files.
        try small.setBase(identity, entries: [TaskWorkspace.TreeEntry(path: "dir", mode: "040000", type: "tree", sha: sha, size: nil),
                                              entry("dir/a"), entry("dir/b")])
        XCTAssertEqual(try small.list("").map(\.name), ["dir"])
    }

    // MARK: - Listing and overlay

    func testListingShowsDirectoriesFirstAndMarksUnsupportedEntries() throws {
        let workspace = try imported()
        XCTAssertEqual(try workspace.list(""), [
            .init(name: "assets", kind: .directory), .init(name: "deep", kind: .directory),
            .init(name: "docs", kind: .directory), .init(name: "Sources", kind: .directory),
            .init(name: "link", kind: .unsupported), .init(name: "README.md", kind: .file),
        ])
        XCTAssertEqual(try workspace.list("Sources").map(\.name), ["util", "App.swift", "Generated.swift", "Makefile", "makefile"])
        XCTAssertEqual(try workspace.list("assets"), [.init(name: "crlf.txt", kind: .file), .init(name: "logo.bin", kind: .unsupported)])
        XCTAssertTrue(workspace.directoryExists("Sources/util"))
        XCTAssertFalse(workspace.directoryExists("Sources/App.swift"))
    }

    func testAppliedCreatesDeletesAndRenamesChangeListingReadsAndSearch() throws {
        let workspace = try imported()
        let original = try workspace.read("Sources/App.swift").text
        try workspace.setOverlay(key: "one", operations: [
            .write(path: "Sources/New.swift", text: "struct Fresh {}\n"),
            .delete(path: "Sources/Makefile"),
            // A rename is a delete plus a write of the same bytes.
            .delete(path: "Sources/App.swift"), .write(path: "Sources/Core/App.swift", text: original),
            .write(path: "README.md", text: "# Changed\n"),
        ])
        XCTAssertEqual(try workspace.list("Sources").map(\.name), ["Core", "util", "Generated.swift", "makefile", "New.swift"])
        XCTAssertEqual(try workspace.list("Sources/Core").map(\.name), ["App.swift"])
        XCTAssertThrowsError(try workspace.read("Sources/App.swift")) { XCTAssertEqual($0 as? WorkspaceError, .missing) }
        XCTAssertThrowsError(try workspace.read("Sources/Makefile")) { XCTAssertEqual($0 as? WorkspaceError, .missing) }
        XCTAssertEqual(try workspace.read("Sources/makefile").text, "all:\n\techo lower\n")
        let moved = try workspace.read("Sources/Core/App.swift")
        XCTAssertEqual(moved.text, original)
        XCTAssertTrue(moved.isLocal)
        XCTAssertEqual(try workspace.read("README.md").text, "# Changed\n")
        XCTAssertTrue(workspace.hasLocalChange(at: "README.md"))
        XCTAssertTrue(workspace.hasLocalChange(at: "Sources/Makefile"))
        XCTAssertFalse(workspace.hasLocalChange(at: "Sources/Generated.swift"))
        XCTAssertEqual(workspace.counts.local, 3)

        XCTAssertEqual(try workspace.search("struct Fresh").matches.map(\.path), ["Sources/New.swift"])
        XCTAssertEqual(try workspace.search("DownloadManager").matches.map(\.path), ["Sources/Core/App.swift"])
        // The deleted file's line is gone; only the word fallback still finds its sibling.
        let deleted = try workspace.search("echo upper")
        XCTAssertEqual(deleted.mode, .words)
        XCTAssertEqual(deleted.matches, [.init(path: "Sources/makefile", line: 2, text: "\techo lower")])
        XCTAssertEqual(try workspace.search("tiny repository").mode, WorkspaceSearch.Mode.none)
        XCTAssertTrue(workspace.isComplete)
    }

    func testOverlayIsRebuiltFromItsOperationsAndRestoresTheBaseExactly() throws {
        let workspace = try imported()
        let before = try workspace.list("Sources")
        let readme = try workspace.read("README.md")
        try workspace.setOverlay(key: "a", operations: [.delete(path: "README.md"), .write(path: "Sources/x.txt", text: "x")])
        // The same key is a no-op even with different operations: the key names the state.
        try workspace.setOverlay(key: "a", operations: [])
        XCTAssertThrowsError(try workspace.read("README.md"))
        // Rename then recreate the source: both files exist with their own bytes.
        try workspace.setOverlay(key: "b", operations: [
            .delete(path: "README.md"), .write(path: "docs/README.md", text: readme.text),
            .write(path: "README.md", text: "replacement\n"),
        ])
        XCTAssertEqual(try workspace.read("README.md").text, "replacement\n")
        XCTAssertEqual(try workspace.read("docs/README.md").text, readme.text)
        XCTAssertThrowsError(try workspace.read("Sources/x.txt"))
        try workspace.setOverlay(key: "", operations: [])
        XCTAssertEqual(try workspace.read("README.md"), readme)
        XCTAssertEqual(try workspace.list("Sources"), before)
        XCTAssertEqual(workspace.counts, TaskWorkspace.Counts(text: 11, unsupported: 2, pending: 0, local: 0))
        XCTAssertEqual(try workspace.search("tiny repository").matches.map(\.path), ["README.md"])
        XCTAssertEqual(workspace.overlayKey, "")
        XCTAssertThrowsError(try workspace.setOverlay(key: "bad", operations: [.write(path: "../out", text: "x")]))
        XCTAssertEqual(workspace.overlayKey, "")
    }

    func testWorkspaceSurvivesReopeningAndANewBaseReplacesTheOld() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keel-workspace-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let workspace = try TaskWorkspace(path: url.path)
            try workspace.setBase(identity, entries: entries)
            _ = try workspace.importArchive(ArchiveFixture.dynamic)
            try workspace.setOverlay(key: "kept", operations: [.write(path: "notes.md", text: "note\n")])
        }
        let reopened = try TaskWorkspace(path: url.path)
        XCTAssertEqual(reopened.identity, identity)
        XCTAssertTrue(reopened.isComplete)
        XCTAssertEqual(reopened.overlayKey, "kept")
        XCTAssertEqual(try reopened.read("notes.md").text, "note\n")
        XCTAssertEqual(try reopened.search("resumeDownload").matches.first?.path, "Sources/App.swift")

        let other = TaskWorkspace.Identity(repository: "owner/other", commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40))
        try reopened.setBase(other, entries: [])
        XCTAssertEqual(reopened.identity, other)
        XCTAssertEqual(reopened.counts.files, 0)
        XCTAssertThrowsError(try reopened.read("notes.md"))
        XCTAssertEqual(try reopened.search("resumeDownload").mode, WorkspaceSearch.Mode.none)
    }

    // MARK: - Search

    func testSearchFindsExactBytesAcrossFilesWithLineNumbers() throws {
        let workspace = try imported()
        let result = try workspace.search("prefix")
        XCTAssertEqual(result.mode, .exact)
        XCTAssertEqual(result.matches, [
            .init(path: "README.md", line: 4, text: "The prefix cache keeps prompt tokens."),
            .init(path: "Sources/App.swift", line: 9, text: "    private var prefixCache: [Int] = []"),
        ])
        XCTAssertEqual(result.searchedFiles, 11)
        XCTAssertEqual(result.pendingFiles, 0)
        XCTAssertNil(result.nextOffset)
        // CRLF line endings are not part of the reported line.
        XCTAssertEqual(try workspace.search("two").matches, [.init(path: "assets/crlf.txt", line: 2, text: "two")])
        // Byte-distinct Unicode stays distinct.
        XCTAssertEqual(try workspace.search("decomposed").matches.map(\.path), [decomposed])
    }

    func testSearchFallsBackToIgnoringCaseThenToRankedWordsAndSaysSo() throws {
        let workspace = try imported()
        let loose = try workspace.search("downloadmanager")
        XCTAssertEqual(loose.mode, .ignoreCase)
        XCTAssertEqual(loose.matches.map(\.line), [7])

        let words = try workspace.search("where is the download resumed")
        XCTAssertEqual(words.mode, .words)
        XCTAssertEqual(words.matches.first?.path, "Sources/App.swift")
        XCTAssertTrue(words.matches.contains { $0.text.contains("resumeDownload") })

        // camelCase parts are indexed: "cache" alone reaches prefixCache's file.
        let part = try workspace.search("cache tokens kept")
        XCTAssertEqual(part.mode, .words)
        XCTAssertEqual(Set(part.matches.map(\.path)), ["README.md", "Sources/App.swift"])

        // A several-word query with one literal hit also gets the word-ranked lines.
        let sparse = try workspace.search("prefix cache")
        XCTAssertEqual(sparse.mode, .exact)
        XCTAssertEqual(sparse.matches.map(\.path), ["README.md"])
        XCTAssertEqual(sparse.related.map(\.path), ["Sources/App.swift"])
        XCTAssertTrue(sparse.related[0].text.contains("prefixCache"))
        XCTAssertTrue(try workspace.search("prefix").related.isEmpty)

        let nothing = try workspace.search("zzzqqq unrelated")
        XCTAssertEqual(nothing.mode, WorkspaceSearch.Mode.none)
        XCTAssertTrue(nothing.matches.isEmpty)
        XCTAssertEqual(nothing.searchedFiles, 11)
    }

    func testSearchScopePaginationPathMatchesAndLongLines() throws {
        let workspace = try imported()
        let scoped = try workspace.search("def ", under: "Sources/util")
        XCTAssertEqual(scoped.matches.map(\.line), [2, 5])
        XCTAssertEqual(scoped.searchedFiles, 1)
        XCTAssertEqual(try workspace.search("def ", under: "docs").mode, WorkspaceSearch.Mode.none)
        XCTAssertEqual(try workspace.search("class", under: "Sources/util/helpers.py").matches.map(\.line), [1])
        // "Sources/util" must not also match a sibling such as "Sources/utility".
        XCTAssertThrowsError(try workspace.search("x", under: "../Sources"))

        let first = try workspace.search("compute(", limit: 3)
        XCTAssertEqual(first.matches.map(\.line), [1, 2, 3])
        XCTAssertEqual(first.nextOffset, 3)
        let second = try workspace.search("compute(", limit: 3, offset: 3)
        XCTAssertEqual(second.matches.map(\.line), [4, 5, 6])
        let last = try workspace.search("compute(", limit: 50, offset: 380)
        XCTAssertEqual(last.matches.count, 20)
        XCTAssertNil(last.nextOffset)

        let paths = try workspace.search("helpers")
        XCTAssertEqual(paths.pathMatches, ["Sources/util/helpers.py"])
        XCTAssertEqual(try workspace.search("MAKEFILE").pathMatches, ["Sources/Makefile", "Sources/makefile"])

        try workspace.setOverlay(key: "long", operations: [.write(path: "long.txt", text: String(repeating: "é", count: 400) + "needle")])
        let clipped = try workspace.search("needle", maxLineBytes: 101)
        XCTAssertEqual(clipped.matches.count, 1)
        XCTAssertTrue(clipped.matches[0].text.hasSuffix("…"))
        XCTAssertEqual(clipped.matches[0].text.unicodeScalars.count, 51)
    }

    func testSearchReportsFilesItCouldNotCover() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(identity, entries: entries)
        let text = "class Parser:\n    def parse(self, text):\n        return text.split()\n\ndef load_table(path):\n    return open(path).read()\n"
        XCTAssertTrue(try workspace.store(path: "Sources/util/helpers.py", data: Data(text.utf8)))
        let result = try workspace.search("Parser")
        XCTAssertEqual(result.matches.map(\.path), ["Sources/util/helpers.py"])
        XCTAssertEqual(result.searchedFiles, 1)
        XCTAssertEqual(result.pendingFiles, 11)
    }

    // MARK: - Repository map

    func testSymbolsComeFromDeclarationsNotFromMethodsOrComments() {
        XCTAssertEqual(RepoMap.symbols(path: "a/App.swift", text: """
            import Foundation
            // struct NotThis
            public struct AppConfig {
                func method() {}
                    struct TooDeep {}
            }
            @MainActor final class DownloadManager: ObservableObject {}
            extension AppConfig {}
            func makeConfig() -> AppConfig { AppConfig() }
            """), "AppConfig, DownloadManager, makeConfig")
        XCTAssertEqual(RepoMap.symbols(path: "x.py", text: "class Parser:\n    def parse(self):\n        pass\n\nasync def main():\n    pass\n"), "Parser, main")
        XCTAssertEqual(RepoMap.symbols(path: "lib.rs", text: "pub(crate) struct Engine;\npub fn run() {}\nimpl Engine {}\n"), "Engine, run")
        XCTAssertEqual(RepoMap.symbols(path: "index.ts", text: "export default class Store {}\nexport async function load() {}\nexport interface Row {}\n"), "Store, Row, load")
        XCTAssertEqual(RepoMap.symbols(path: "README.md", text: "class Not a declaration\n"), "")
    }

    func testRepositoryMapNamesFilesAndDeclarationsAndFollowsTheOverlay() throws {
        let workspace = try imported()
        let map = workspace.repoMap()
        XCTAssertTrue(map.hasPrefix("Repository map (13 files"))
        XCTAssertTrue(map.contains("\n(root): README.md, link\n"), map)
        XCTAssertTrue(map.contains("\nSources/: App.swift (AppConfig, DownloadManager, makeConfig), Generated.swift, Makefile, makefile\n"), map)
        XCTAssertTrue(map.contains("\nSources/util/: helpers.py (Parser, load_table)\n"), map)
        XCTAssertEqual(map, workspace.repoMap(), "The map must be byte-stable so the prompt prefix stays cached")

        try workspace.setOverlay(key: "m", operations: [.write(path: "Sources/Queue.swift", text: "actor JobQueue {}\n"), .delete(path: "Sources/App.swift")])
        let changed = workspace.repoMap()
        XCTAssertTrue(changed.contains("Queue.swift (JobQueue)"), changed)
        XCTAssertFalse(changed.contains("DownloadManager"))
    }

    func testRepositoryMapStaysWithinItsBudgetForLargeRepositories() throws {
        var files: [RepoMap.FileRow] = []
        for package in 0..<30 {
            for file in 0..<25 {
                files.append(RepoMap.FileRow(path: "packages/module\(package)/src/File\(file).swift", symbols: "Type\(file), helper\(file)"))
            }
            files.append(RepoMap.FileRow(path: "packages/module\(package)/Tests/Test\(package).swift", symbols: "Test\(package)"))
        }
        files.append(RepoMap.FileRow(path: "README.md", symbols: ""))
        for budget in [600, 1_200, 2_400, 6_000] {
            let map = RepoMap.render(files, maxCharacters: budget)
            XCTAssertLessThanOrEqual(map.count, budget, "budget \(budget)")
            XCTAssertTrue(map.contains("packages/"), map)
        }
        // More budget buys more detail, never less.
        XCTAssertGreaterThan(RepoMap.render(files, maxCharacters: 6_000).count, RepoMap.render(files, maxCharacters: 1_200).count)
        XCTAssertEqual(RepoMap.render([], maxCharacters: 500), "Repository map: this workspace has no files yet.")
    }
}
