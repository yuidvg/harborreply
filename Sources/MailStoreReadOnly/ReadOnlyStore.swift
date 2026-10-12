import Foundation
import Darwin
import CryptoKit

public enum StoreFailure: String, Error { case permission, unavailable, changed, malformed, tooLarge, depth }

/// A closed capability: no initializer, descriptor, URL, or mutation is exported.
/// For clients restricted to this API, induction over every available operation
/// preserves source bytes: next uses readdir/openat/fstat; content uses pread.
/// Swift unsafe code and unrelated OS APIs are outside this guarantee.
public final class MailEntry {
    private let descriptor: Int32
    public let key: String
    public let fingerprint: String
    public let mailboxHint: String
    fileprivate init(descriptor: Int32, key: String, fingerprint: String, mailboxHint: String) {
        self.descriptor = descriptor; self.key = key; self.fingerprint = fingerprint; self.mailboxHint = mailboxHint
    }
    deinit { Darwin.close(descriptor) }
    public func content(maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 16 * 1024 * 1024 else { throw StoreFailure.tooLarge }
        guard try stamp(descriptor) == fingerprint else { throw StoreFailure.changed }
        var header = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &header, header.count, 0)
        guard count > 0, let newline = header.prefix(count).firstIndex(of: 10), newline > 0 else { throw StoreFailure.malformed }
        let digits = header[..<newline].prefix(while: { (48...57).contains($0) })
        guard !digits.isEmpty, header[digits.count..<newline].allSatisfy({ $0 == 32 || $0 == 13 }),
              let size = Int(String(decoding: digits, as: UTF8.self)), size > 0 else { throw StoreFailure.malformed }
        guard size <= maximumBytes else { throw StoreFailure.tooLarge }
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let read = pread(descriptor, bytes.baseAddress!.advanced(by: offset), size - offset, off_t(newline + 1 + offset))
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw StoreFailure.changed }
                offset += read
            }
        }
        guard try stamp(descriptor) == fingerprint else { throw StoreFailure.changed }
        return data
    }
}

private func stamp(_ fd: Int32) throws -> String {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw StoreFailure.unavailable }
    return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
}
private func failure() -> StoreFailure { errno == EPERM || errno == EACCES ? .permission : .unavailable }
private final class Directory {
    let pointer: UnsafeMutablePointer<DIR>
    let relative: String
    let fingerprint: String
    init(_ fd: Int32, relative: String) throws {
        let fingerprint: String
        do { fingerprint = try stamp(fd) } catch { Darwin.close(fd); throw error }
        guard let pointer = fdopendir(fd) else { Darwin.close(fd); throw failure() }
        self.pointer = pointer; self.relative = relative; self.fingerprint = fingerprint
    }
    deinit { closedir(pointer) }
}

/// Depth-bounded traversal. Every path component is opened without following
/// symlinks, including the root. Never uses Mail's live SQLite database.
public final class ReadOnlyMailStore {
    private var stack: [Directory]
    private let rootKey: String
    public init(root: String) throws {
        guard root.hasPrefix("/"), !root.utf8.contains(0) else { throw StoreFailure.unavailable }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        do {
            for part in root.split(separator: "/") {
                guard part != ".." else { throw StoreFailure.unavailable }
                let child = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw failure() }
                Darwin.close(fd); fd = child
            }
        } catch { Darwin.close(fd); throw error }
        rootKey = root
        stack = [try Directory(fd, relative: "")]
    }
    public func next() throws -> MailEntry? {
        while let directory = stack.last {
            errno = 0
            guard let pointer = readdir(directory.pointer) else {
                guard errno == 0 else { throw failure() }
                guard try stamp(dirfd(directory.pointer)) == directory.fingerprint else { throw StoreFailure.changed }
                stack.removeLast(); continue
            }
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            let parent = dirfd(directory.pointer)
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
            let kind = info.st_mode & S_IFMT
            let relative = directory.relative + "/" + name
            if kind == S_IFDIR {
                guard stack.count < 128 else { throw StoreFailure.depth }
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw failure() }
                stack.append(try Directory(fd, relative: relative))
            } else if kind == S_IFREG && name.hasSuffix(".emlx") {
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw failure() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { Darwin.close(fd); throw StoreFailure.changed }
                do {
                    // Root path, not its changing directory mtime, determines identity.
                    let key = SHA256.hash(data: Data((rootKey + relative).utf8)).map { String(format: "%02x", $0) }.joined()
                    let hint = relative.split(separator: "/").last(where: { $0.hasSuffix(".mbox") }).map(String.init) ?? ""
                    return try MailEntry(descriptor: fd, key: key, fingerprint: stamp(fd), mailboxHint: hint)
                } catch { Darwin.close(fd); throw error }
            }
        }
        return nil
    }
}
