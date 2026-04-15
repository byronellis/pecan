import Testing
import Foundation
@testable import PecanOverlayCore

// MARK: - Test helpers

private func makeTempDir() throws -> String {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cow-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.path
}

private func makeOverlay() throws -> (core: COWOverlayCore, lower: String, upper: String, cleanup: () -> Void) {
    let lower = try makeTempDir()
    let upper = try makeTempDir()
    let core = COWOverlayCore(lower: lower, upper: upper)
    let cleanup = {
        try? FileManager.default.removeItem(atPath: lower)
        try? FileManager.default.removeItem(atPath: upper)
    }
    return (core, lower, upper, cleanup)
}

// Write a file into the lower directory directly (simulates read-only project files).
private func writeLower(_ lower: String, path: String, content: String) throws {
    let full = lower + path
    let dir = (full as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try content.write(toFile: full, atomically: true, encoding: .utf8)
}

// Read a file from the upper directory directly to verify COW behaviour.
private func readUpper(_ upper: String, path: String) throws -> String? {
    let full = upper + path
    guard FileManager.default.fileExists(atPath: full) else { return nil }
    return try String(contentsOfFile: full, encoding: .utf8)
}

// MARK: - Read tests

@Suite("COWOverlayCore: read")
struct ReadTests {
    @Test("read returns correct bytes from lower layer file")
    func readFromLower() async throws {
        let (core, lower, _, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/hello.txt", content: "Hello, world!")

        let data = await core.readFile(at: "/hello.txt", offset: 0, size: 5)
        let result = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        #expect(result == "Hello")
    }

    @Test("read at offset returns correct slice")
    func readWithOffset() async throws {
        let (core, lower, _, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/data.txt", content: "ABCDEFGHIJ")

        let data = await core.readFile(at: "/data.txt", offset: 3, size: 4)
        let result = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        #expect(result == "DEFG")
    }

    @Test("read at offset past end returns empty data")
    func readPastEnd() async throws {
        let (core, lower, _, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/small.txt", content: "Hi")

        // FileHandle.readData(ofLength:) at EOF returns empty Data, not nil.
        let data = await core.readFile(at: "/small.txt", offset: 100, size: 10)
        // Either nil (file not opened) or empty data is acceptable at EOF.
        // Since the file exists, we expect non-nil but empty.
        #expect(data != nil)
        #expect((data ?? Data()).isEmpty)
    }

    @Test("read prefers upper layer over lower layer")
    func readPrefersUpper() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/file.txt", content: "lower content")
        // Write directly to upper to simulate a previous COW write
        let upperPath = upper + "/file.txt"
        try "upper content".write(toFile: upperPath, atomically: true, encoding: .utf8)

        let data = await core.readFile(at: "/file.txt", offset: 0, size: 50)
        let result = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        #expect(result == "upper content")
    }

    @Test("read returns nil for non-existent file")
    func readNonExistent() async throws {
        let (core, _, _, cleanup) = try makeOverlay()
        defer { cleanup() }

        let data = await core.readFile(at: "/nope.txt", offset: 0, size: 10)
        #expect(data == nil)
    }
}

// MARK: - COW copy tests

@Suite("COWOverlayCore: copy-on-write semantics")
struct COWTests {
    @Test("writeFile COW-copies from lower before modifying")
    func cowCopyOnWrite() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/original.txt", content: "original")

        // Write through the overlay — should trigger a COW copy
        let newContent = Data("modified".utf8)
        let errno = await core.writeFile(at: "/original.txt", offset: 0, data: newContent)
        #expect(errno == 0)

        // Lower should be unchanged
        let lowerContent = try String(contentsOfFile: lower + "/original.txt", encoding: .utf8)
        #expect(lowerContent == "original")

        // Upper should have the new content
        let upperContent = try readUpper(upper, path: "/original.txt")
        #expect(upperContent == "modified")
    }

    @Test("cowCopy does not overwrite existing upper file")
    func cowCopyDoesNotOverwriteUpper() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/shared.txt", content: "lower")
        let upperPath = upper + "/shared.txt"
        try "already-in-upper".write(toFile: upperPath, atomically: true, encoding: .utf8)

        await core.cowCopy("/shared.txt")

        let upperContent = try String(contentsOfFile: upperPath, encoding: .utf8)
        #expect(upperContent == "already-in-upper")
    }

    @Test("cowCopy is no-op when file is not in lower")
    func cowCopyNonExistentLower() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        await core.cowCopy("/ghost.txt")

        #expect(!FileManager.default.fileExists(atPath: upper + "/ghost.txt"))
    }
}

// MARK: - Whiteout tests

@Suite("COWOverlayCore: whiteout / delete")
struct WhiteoutTests {
    @Test("deleting lower-only file creates whiteout")
    func deleteCreatesWhiteout() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/todelete.txt", content: "bye")

        let errno = await core.deleteFile(at: "/todelete.txt")
        #expect(errno == 0)

        // Whiteout marker should appear in upper
        #expect(FileManager.default.fileExists(atPath: upper + "/.wh.todelete.txt"))
        // Original lower file still exists (we never touch the lower layer)
        #expect(FileManager.default.fileExists(atPath: lower + "/todelete.txt"))
    }

    @Test("deleting upper-only file removes it without whiteout")
    func deleteUpperOnlyNoWhiteout() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        let upperPath = upper + "/newfile.txt"
        try "new".write(toFile: upperPath, atomically: true, encoding: .utf8)

        let errno = await core.deleteFile(at: "/newfile.txt")
        #expect(errno == 0)

        #expect(!FileManager.default.fileExists(atPath: upperPath))
        #expect(!FileManager.default.fileExists(atPath: upper + "/.wh.newfile.txt"))
    }

    @Test("isWhitedOut returns true for whited-out name")
    func isWhitedOut() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        // Manually create a whiteout
        try "".write(toFile: upper + "/.wh.deleted.txt", atomically: true, encoding: .utf8)

        #expect(await core.isWhitedOut("deleted.txt", inDir: "/"))
        #expect(!(await core.isWhitedOut("present.txt", inDir: "/")))
    }

    @Test("creating file removes existing whiteout")
    func createFileRemovesWhiteout() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        // Manually create a whiteout for /resurrected.txt
        try "".write(toFile: upper + "/.wh.resurrected.txt", atomically: true, encoding: .utf8)

        let errno = await core.createFile(at: "/resurrected.txt")
        #expect(errno == 0)

        #expect(!FileManager.default.fileExists(atPath: upper + "/.wh.resurrected.txt"))
        #expect(FileManager.default.fileExists(atPath: upper + "/resurrected.txt"))
    }
}

// MARK: - Virtual file generation tests

@Suite("COWOverlayCore: virtual files (diff / changes / status)")
struct VirtualFileTests {
    @Test("generateChanges lists added files with A prefix")
    func changesAdded() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try FileManager.default.createDirectory(atPath: upper, withIntermediateDirectories: true)
        try "new content".write(toFile: upper + "/added.txt", atomically: true, encoding: .utf8)

        let changes = await core.generateChanges()
        #expect(changes.contains("A /added.txt"))
    }

    @Test("generateChanges lists modified files with M prefix")
    func changesModified() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/existing.txt", content: "original")
        try "modified".write(toFile: upper + "/existing.txt", atomically: true, encoding: .utf8)

        let changes = await core.generateChanges()
        #expect(changes.contains("M /existing.txt"))
    }

    @Test("generateChanges lists deleted files with D prefix")
    func changesDeleted() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/removed.txt", content: "gone")
        // Create whiteout
        try "".write(toFile: upper + "/.wh.removed.txt", atomically: true, encoding: .utf8)

        let changes = await core.generateChanges()
        #expect(changes.contains("D /removed.txt"))
    }

    @Test("generateDiff produces non-empty output for modified file")
    func diffProducesOutput() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/code.py", content: "x = 1\n")
        try "x = 2\n".write(toFile: upper + "/code.py", atomically: true, encoding: .utf8)

        let diff = await core.generateDiff()
        #expect(!diff.isEmpty)
        #expect(diff.contains("-x = 1"))
        #expect(diff.contains("+x = 2"))
    }

    @Test("generateDiff is empty when no files in upper")
    func diffEmptyWhenNoChanges() async throws {
        let (core, lower, _, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/untouched.txt", content: "original")

        let diff = await core.generateDiff()
        #expect(diff.isEmpty)
    }

    @Test("generateStatus returns valid JSON with correct counts")
    func statusJSON() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/a.txt", content: "a")
        try writeLower(lower, path: "/b.txt", content: "b")
        // Modify a, add c, delete b
        try "modified-a".write(toFile: upper + "/a.txt", atomically: true, encoding: .utf8)
        try "new-c".write(toFile: upper + "/c.txt", atomically: true, encoding: .utf8)
        try "".write(toFile: upper + "/.wh.b.txt", atomically: true, encoding: .utf8)

        let status = await core.generateStatus()
        #expect(status.contains("\"modified\" : 1"))
        #expect(status.contains("\"added\" : 1"))
        #expect(status.contains("\"deleted\" : 1"))
    }
}

// MARK: - Cache behaviour tests

@Suite("COWOverlayCore: virtual file cache")
struct CacheTests {
    @Test("virtualContent is cached after first access")
    func cacheHit() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/file.txt", content: "v1")
        try "modified".write(toFile: upper + "/file.txt", atomically: true, encoding: .utf8)

        // First access — populates cache
        let first = await core.virtualContent(for: "/.pecan/changes")

        // Write a second file directly to upper (bypass the API to avoid invalidation)
        // This simulates the cache being stale — the cache should return the old value.
        try "extra".write(toFile: upper + "/extra.txt", atomically: true, encoding: .utf8)

        // Second access — should return cached value (extra.txt not reflected yet)
        let second = await core.virtualContent(for: "/.pecan/changes")
        #expect(first == second, "Cache should return same value without invalidation")
    }

    @Test("invalidateFile clears diff and changes cache for affected path")
    func invalidateFileClears() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/watch.txt", content: "v1")
        try "v2".write(toFile: upper + "/watch.txt", atomically: true, encoding: .utf8)

        // Warm the cache
        _ = await core.virtualContent(for: "/.pecan/changes")

        // Invalidate and write new content
        await core.invalidateFile("/watch.txt")
        try "v3".write(toFile: upper + "/watch.txt", atomically: true, encoding: .utf8)

        // Re-access — should reflect the update
        let updated = await core.virtualContent(for: "/.pecan/changes")
        let text = updated.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
        #expect(text.contains("/watch.txt"))
    }

    @Test("per-file diff cache: only dirty file is re-diffed")
    func perFileDiffCacheOnlyReDiffs() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        // Set up two modified files
        try writeLower(lower, path: "/a.txt", content: "a-lower\n")
        try writeLower(lower, path: "/b.txt", content: "b-lower\n")
        try "a-upper\n".write(toFile: upper + "/a.txt", atomically: true, encoding: .utf8)
        try "b-upper\n".write(toFile: upper + "/b.txt", atomically: true, encoding: .utf8)

        // First diff call — populates perFileDiffCache for both
        let diff1 = await core.generateDiff()
        #expect(diff1.contains("a-upper"))
        #expect(diff1.contains("b-upper"))

        // Mark only /a.txt as dirty
        await core.invalidateFile("/a.txt")
        // Update /a.txt in upper
        try "a-v3\n".write(toFile: upper + "/a.txt", atomically: true, encoding: .utf8)

        // Second diff — /b.txt should use cache, /a.txt should be re-diffed
        let diff2 = await core.generateDiff()
        #expect(diff2.contains("a-v3"))
        #expect(diff2.contains("b-upper"), "b.txt diff should come from cache unchanged")
    }
}

// MARK: - Rename tests

@Suite("COWOverlayCore: rename")
struct RenameTests {
    @Test("rename moves file from lower to upper at new path")
    func renameFromLower() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/old.txt", content: "content")

        let errno = await core.rename(from: "/old.txt", to: "/new.txt")
        #expect(errno == 0)

        // New path should exist in upper
        #expect(FileManager.default.fileExists(atPath: upper + "/new.txt"))
        // Old path should be whited out (it existed in lower)
        #expect(FileManager.default.fileExists(atPath: upper + "/.wh.old.txt"))
        // Lower is untouched
        #expect(FileManager.default.fileExists(atPath: lower + "/old.txt"))
    }

    @Test("rename within upper moves file without whiteout if not in lower")
    func renameUpperOnly() async throws {
        let (core, _, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try "hello".write(toFile: upper + "/a.txt", atomically: true, encoding: .utf8)

        let errno = await core.rename(from: "/a.txt", to: "/b.txt")
        #expect(errno == 0)

        #expect(!FileManager.default.fileExists(atPath: upper + "/a.txt"))
        #expect(!FileManager.default.fileExists(atPath: upper + "/.wh.a.txt"))
        #expect(FileManager.default.fileExists(atPath: upper + "/b.txt"))
    }
}

// MARK: - Directory listing tests

@Suite("COWOverlayCore: listDirectory")
struct ListDirectoryTests {
    @Test("listDirectory unions upper and lower entries")
    func unionListing() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/lower-only.txt", content: "l")
        try "u".write(toFile: upper + "/upper-only.txt", atomically: true, encoding: .utf8)

        let entries = await core.listDirectory("/")
        let names = entries.map(\.name)
        #expect(names.contains("lower-only.txt"))
        #expect(names.contains("upper-only.txt"))
    }

    @Test("listDirectory hides whited-out entries")
    func hideWhiteouts() async throws {
        let (core, lower, upper, cleanup) = try makeOverlay()
        defer { cleanup() }

        try writeLower(lower, path: "/visible.txt", content: "yes")
        try writeLower(lower, path: "/hidden.txt", content: "no")
        // Create whiteout for hidden.txt
        try "".write(toFile: upper + "/.wh.hidden.txt", atomically: true, encoding: .utf8)

        let entries = await core.listDirectory("/")
        let names = entries.map(\.name)
        #expect(names.contains("visible.txt"))
        #expect(!names.contains("hidden.txt"))
        #expect(!names.contains(".wh.hidden.txt"))
    }
}
