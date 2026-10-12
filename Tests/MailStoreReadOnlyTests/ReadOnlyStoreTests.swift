import XCTest
import Darwin
import MailStoreReadOnly

final class ReadOnlyStoreTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // /var is a macOS symlink; a capability requires the canonical root.
        let canonical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical))
    }
    func testByteCountExcludesTrailerAndPreservesOriginal() throws {
        let root = try directory(), file = root.appendingPathComponent("1.emlx")
        let data = Data("5\nhelloTRAILER".utf8)
        try data.write(to: file)
        let store = try ReadOnlyMailStore(root: root.path)
        let entry = try XCTUnwrap(store.next())
        XCTAssertEqual(try entry.content(), Data("hello".utf8))
        XCTAssertNil(try store.next())
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testAppleMailSpacePaddedByteCount() throws {
        let root = try directory()
        try Data("5         \nhelloTRAILER".utf8).write(to: root.appendingPathComponent("1.emlx"))
        let entry = try XCTUnwrap(ReadOnlyMailStore(root: root.path).next())
        XCTAssertEqual(try entry.content(), Data("hello".utf8))
    }
    func testReplacementAfterMetadataFailsClosed() throws {
        let root = try directory(), file = root.appendingPathComponent("1.emlx")
        try Data("5\nhello".utf8).write(to: file)
        let entry = try XCTUnwrap(ReadOnlyMailStore(root: root.path).next())
        try Data("7\nchanged".utf8).write(to: file, options: [])
        XCTAssertThrowsError(try entry.content())
    }
    func testDirectoryMutationCannotBeReportedAsComplete() throws {
        let root = try directory()
        try Data("5\nhello".utf8).write(to: root.appendingPathComponent("1.emlx"))
        let store = try ReadOnlyMailStore(root: root.path)
        XCTAssertNotNil(try store.next())
        try Data("5\nhello".utf8).write(to: root.appendingPathComponent("2.emlx"))
        XCTAssertThrowsError(try { while try store.next() != nil {} }())
    }
    func testSymlinksAreNeverFollowed() throws {
        let root = try directory(), outside = try directory()
        try Data("5\nhello".utf8).write(to: outside.appendingPathComponent("1.emlx"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("2.emlx"), withDestinationURL: outside.appendingPathComponent("1.emlx"))
        XCTAssertNil(try ReadOnlyMailStore(root: root.path).next())
        XCTAssertThrowsError(try ReadOnlyMailStore(root: root.appendingPathComponent("linked").path))
    }
    func testMalformedTruncatedAndLargeDeclarationsDoNotAllocate() throws {
        for raw in ["-1\nx", "9999999999999999999999999999\nx", "100\nx", "17000000\nx"] {
            let root = try directory()
            try Data(raw.utf8).write(to: root.appendingPathComponent("1.emlx"))
            let entry = try XCTUnwrap(ReadOnlyMailStore(root: root.path).next())
            XCTAssertThrowsError(try entry.content())
        }
    }
}
