import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum SecureFileError: Error { case unsafePath, cannotCreate, cannotReplace, exists }

/// `security find-generic-password -w` prints an ASCII secret unchanged, and prints a secret that
/// contains non-ASCII bytes as hex. Both shapes occur for the JSON documents Lilt stores.
public enum KeychainPassword {
    public static func decode(_ output: Data) -> Data {
        var data = output
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard data.count >= 2, data.count.isMultiple(of: 2), data.allSatisfy(isHex),
              let decoded = hex(data),
              (try? JSONSerialization.jsonObject(with: decoded)) is [String: Any] else { return data }
        return decoded
    }
    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
    }
    private static func hex(_ data: Data) -> Data? {
        var out = Data(); out.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(index, offsetBy: 2)
            guard let byte = UInt8(String(bytes: data[index..<next], encoding: .ascii) ?? "", radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
public enum SecureFiles {
    public static func directory(_ url: URL) throws {
        // Inspect every existing path component, including dangling symlinks.
        try rejectSymlinks(url)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw SecureFileError.unsafePath }
            // Checked on every pass of the monitor; changing the mode only when it is wrong keeps that a read.
            if info.st_mode & 0o777 == 0o700 { return }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public static func rejectSymlinks(_ url: URL) throws {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            var info = stat()
            if lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw SecureFileError.unsafePath }
            candidate.deleteLastPathComponent()
        }
    }
    public static func write(_ data: Data, to url: URL) throws {
        try rejectSymlinks(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".lilt-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecureFileError.cannotCreate }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        try writeAll(data, to: fd)
        try rejectSymlinks(url)
        guard rename(temp.path, url.path) == 0 else { throw SecureFileError.cannotReplace }
        syncDirectory(url.deletingLastPathComponent())
    }
    /// A new 0600 file at `url`, complete or not at all, that never replaces what is there: an existing file, a
    /// directory or a dangling symlink makes it fail with `exists`. For files the user names, such as an export.
    /// Symlinks above the file are the user's own layout and are followed.
    public static func create(_ data: Data, at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".lilt-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecureFileError.cannotCreate }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        try writeAll(data, to: fd)
        // link() fails when anything already has the name, which rename() would silently replace.
        guard link(temp.path, url.path) == 0 else { throw errno == EEXIST ? SecureFileError.exists : SecureFileError.cannotReplace }
        syncDirectory(parent)
    }
    private static func syncDirectory(_ url: URL) {
        let parentFD = open(url.path, O_RDONLY)
        if parentFD >= 0 { _ = fsync(parentFD); close(parentFD) }
    }
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                #elseif canImport(Glibc)
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                #else
                let count = Musl.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecureFileError.cannotReplace }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SecureFileError.cannotReplace }
    }
}
