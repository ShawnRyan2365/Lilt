import Foundation
import Darwin

public enum SecureFileError: Error { case unsafePath, cannotCreate, cannotReplace }
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
