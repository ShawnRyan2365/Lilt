import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One quota report a Claude Code session handed its status line. It holds the rate limits and nothing else of the
/// session: no prompt, token, email or account name. `scope` says which login the session was on (the default login
/// or one project), which is how a reader tells its own events from a stray file.
public struct LiveUsageEvent: Codable, Equatable, Sendable {
    public static let defaultScope = "default"
    public static func projectScope(_ id: UUID) -> String { "project-" + id.uuidString }

    public let id: String
    public let scope: String
    public let snapshot: UsageSnapshot

    public init(id: String, scope: String, snapshot: UsageSnapshot) {
        self.id = id
        self.scope = scope
        self.snapshot = snapshot
    }
}

public struct LiveUsageBatch: Codable, Equatable, Sendable {
    public let events: [LiveUsageEvent]
    /// Some events were dropped (the spool overflowed) or could not be read. What is missing stays unknown: the
    /// reader keeps asking the endpoint instead of taking the gap for spare quota.
    public let hasGaps: Bool

    public init(events: [LiveUsageEvent], hasGaps: Bool) {
        self.events = events
        self.hasGaps = hasGaps
    }
}

/// A directory with one file per status line event. Several sessions report at once, and with one shared file the
/// last writer used to replace what the others had just written, high readings included. Each event is written to a
/// hidden temporary file and renamed into place, so a reader never sees half of one, and two writers never touch the
/// same file. The reader takes every event there is, then removes them.
///
/// The macOS status line script writes the same layout from the shell; `record` is the format both use.
public enum LiveUsageSpool {
    public static let maximumEvents = 512
    /// A writer or reader that died while holding the lock must not block the spool for good. Holding it takes
    /// milliseconds.
    public static let staleLock: TimeInterval = 30
    public static let lockName = ".lock"
    public static let gapName = ".gap"

    /// The file contents of one event: `{"id", "scope", "at", "rate_limits"}`, the limits exactly as the session gave them.
    public static func record(id: String, scope: String, at: Date, limits: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(limits) else { throw SecureFileError.cannotCreate }
        return try JSONSerialization.data(withJSONObject: ["id": id, "scope": scope, "at": at.timeIntervalSince1970, "rate_limits": limits])
    }

    /// Names sort by the second they were written, then by writer, so pruning drops the oldest first.
    public static func fileName(id: String, at: Date, process: Int32 = getpid()) -> String {
        String(format: "%010lld", Int64(max(0, at.timeIntervalSince1970))) + "-\(process)-\(id).json"
    }

    public static func write(_ record: Data, id: String, at: Date, to directory: URL) throws {
        try SecureFiles.directory(directory)
        try SecureFiles.write(record, to: directory.appendingPathComponent(fileName(id: id, at: at)))
        if (try? eventFiles(directory).count).map({ $0 > maximumEvents }) == true {
            if lock(directory) { defer { unlock(directory) }; _ = prune(directory) }
        }
    }

    /// Every event waiting in `directory` that belongs to `scope`, oldest first, after which they are gone. A lock
    /// held by someone else leaves them for the next call; that is a delay, not a gap.
    public static func drain(_ directory: URL, scope: String, at now: Date = .now) -> LiveUsageBatch {
        guard FileManager.default.fileExists(atPath: directory.path), lock(directory) else {
            return LiveUsageBatch(events: [], hasGaps: false)
        }
        defer { unlock(directory) }
        let marker = directory.appendingPathComponent(gapName)
        var gaps = FileManager.default.fileExists(atPath: marker.path)
        var events: [LiveUsageEvent] = [], seen = Set<String>()
        do {
            if prune(directory) { gaps = true }
            for file in try eventFiles(directory) {
                let data = try? Data(contentsOf: file)
                guard (try? FileManager.default.removeItem(at: file)) != nil else {
                    // Left in place it would be read again on every call; dropped, it is a gap like any other.
                    gaps = true; continue
                }
                guard let data, let event = UsageParser.parseStatusLineEvent(data), event.scope == scope else { gaps = true; continue }
                // Two files with one id are one event written twice, not two readings.
                guard seen.insert(event.id).inserted else { continue }
                events.append(event)
            }
            removeAbandoned(directory, at: now)
        } catch { gaps = true }
        if gaps { try? FileManager.default.removeItem(at: marker) }
        events.sort { ($0.snapshot.sampledAt, $0.id) < ($1.snapshot.sampledAt, $1.id) }
        return LiveUsageBatch(events: events, hasGaps: gaps)
    }

    /// Whether anything is waiting, without taking it.
    public static func hasPending(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(gapName).path)
            || ((try? eventFiles(directory).isEmpty) == false)
    }

    private static func eventFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func lock(_ directory: URL) -> Bool {
        let path = directory.appendingPathComponent(lockName).path
        if mkdir(path, 0o700) == 0 { return true }
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) > staleLock else { return false }
        _ = rmdir(path)
        return mkdir(path, 0o700) == 0
    }

    private static func unlock(_ directory: URL) {
        _ = rmdir(directory.appendingPathComponent(lockName).path)
    }

    /// Drops the oldest events beyond `maximumEvents` and says whether any went. Called with the lock held.
    private static func prune(_ directory: URL) -> Bool {
        guard let files = try? eventFiles(directory), files.count > maximumEvents else { return false }
        for file in files.prefix(files.count - maximumEvents) { try? FileManager.default.removeItem(at: file) }
        try? SecureFiles.write(Data(), to: directory.appendingPathComponent(gapName))
        return true
    }

    /// Temporary files of writers that died before renaming. A live writer renames within milliseconds.
    private static func removeAbandoned(_ directory: URL, at now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent != lockName && file.lastPathComponent != gapName {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// How a batch of status line events becomes readings of the account a scope is on.
public enum LiveUsageFold {
    /// The readings to record, in order, each one the highest use seen so far of its window. An event counts when
    /// it was taken after the switch to this account, is less than `maximumAge` old, is not older than what is
    /// already known, and its windows reset when the known reading's do: a session that has not followed a switch
    /// yet reports another account's windows. A lower figure for the same window is a session telling what it saw
    /// at its own last request, so it never lowers the record. With nothing known there is nothing to match the
    /// windows against, and no event is taken.
    public static func readings(_ events: [LiveUsageEvent], scope: String, known: UsageSnapshot?, since switchAt: Date,
                                at now: Date, maximumAge: TimeInterval = 600) -> [UsageSnapshot] {
        var current = known, accepted: [UsageSnapshot] = []
        for event in events.sorted(by: { ($0.snapshot.sampledAt, $0.id) < ($1.snapshot.sampledAt, $1.id) }) where event.scope == scope {
            let live = event.snapshot, age = now.timeIntervalSince(live.sampledAt)
            guard let base = current, live.sampledAt > switchAt, age >= 0, age < maximumAge,
                  live.sampledAt >= base.sampledAt, live.sharesWindows(with: base, at: now) else { continue }
            let reading = live.keepingHigher(than: base)
            accepted.append(reading)
            current = reading
        }
        return accepted
    }
}
