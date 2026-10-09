import Foundation
import Darwin

public enum SecureFileError: Error { case unsafePath, cannotCreate, cannotReplace }

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
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SecureFileError.unsafePath }
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
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecureFileError.cannotReplace }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SecureFileError.cannotReplace }
        try rejectSymlinks(url)
        guard rename(temp.path, url.path) == 0 else { throw SecureFileError.cannotReplace }
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parentFD >= 0 { _ = fsync(parentFD); close(parentFD) }
    }
}
