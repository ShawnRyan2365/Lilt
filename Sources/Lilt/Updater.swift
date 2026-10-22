import AppKit
import CryptoKit
import LiltCore

/// Redirects are followed only while they stay on GitHub over HTTPS: release images are served from
/// `release-assets.githubusercontent.com` after a redirect from `github.com`.
final class GitHubOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdateFeed.allowsDownload) == true ? request : nil)
    }
}

/// Finds a newer Lilt on GitHub and installs it in place: download the release image, check it, swap the app
/// bundle where it is and open it again. Nothing here touches accounts or credentials.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable {
        case idle, checking, current
        case available(UpdateRelease)
        case downloading(UpdateRelease, Double)
        case installing(UpdateRelease)
        case failed(String, UpdateRelease?)
    }
    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    /// Set for a few seconds after a check the user asked for, so the menu bar panel can say how it went.
    private(set) var reportsResult = false
    /// The running version. Nil for a build that is not a packaged app, which has no bundle to replace.
    let current: AppVersion?
    /// The bundle an update replaces and then opens.
    let target: URL

    init() {
        #if DEBUG
        // LILT_UPDATE_FROM=<version> pretends to be that version; LILT_UPDATE_TARGET=<path to an .app> installs over
        // that copy instead of the running one, so the whole path can be tried without touching the installed app.
        let environment = ProcessInfo.processInfo.environment
        current = AppVersion(environment["LILT_UPDATE_FROM"] ?? AppBuild.version)
        target = environment["LILT_UPDATE_TARGET"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
        #else
        current = AppVersion(AppBuild.version)
        target = Bundle.main.bundleURL
        #endif
    }

    var release: UpdateRelease? {
        switch phase {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        case .failed(_, let release): release
        case .idle, .checking, .current: nil
        }
    }
    /// A background check runs without changing `phase`, so what is on screen does not flicker every few hours.
    private var checkInFlight = false
    var working: Bool {
        if checkInFlight { return true }
        switch phase { case .checking, .downloading, .installing: return true; default: return false }
    }

    /// Called from the monitor loop. Spends at most one request every `UpdateFeed.interval`.
    func checkIfDue(enabled: Bool) {
        guard enabled, current != nil, !working, UpdateFeed.due(lastCheck: lastCheck, now: .now) else { return }
        Task { await check(manual: false) }
    }

    /// A background check that fails stays quiet and keeps what was known; one the user asked for says why.
    func check(manual: Bool) async {
        guard let current, !working else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        if manual { phase = .checking }
        lastCheck = .now
        do {
            phase = try await Self.newest(after: current).map(Phase.available) ?? .current
        } catch {
            if manual { phase = .failed(Self.message(error), nil) }
        }
        if manual { flashResult() }
    }

    private func flashResult() {
        reportsResult = true
        Task { try? await Task.sleep(for: .seconds(4)); reportsResult = false }
    }

    /// Downloads and installs the release found by the last check, then quits so the new copy can open.
    /// `blocker` names work that must not be cut off by quitting, such as a switch or a token renewal in flight.
    func install(blocker: @escaping () -> String?) async {
        guard let release, !working else { return }
        // Work in progress is waited for after the download rather than refused here: usage reads come and go all the time.
        if let reason = UpdateFeed.installBlocker(bundlePath: target.path) ?? permissionBlocker {
            phase = .failed(reason, release); return
        }
        phase = .downloading(release, 0)
        var work: URL?
        do {
            // A folder on the app's own volume, so the final swap is a rename rather than a copy.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            work = folder
            let image = folder.appendingPathComponent("Lilt-\(release.version).dmg")
            try await Self.download(release, to: image) { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.phase { self?.phase = .downloading(release, fraction) }
                }
            }
            phase = .installing(release)
            let staged = try await Task.detached { try Self.stage(image, in: folder, release: release) }.value
            try await waitUntilClear(blocker)
            // From here to quitting nothing suspends, so no switch or renewal can start in between.
            // Finder and LaunchServices then show the install time and read the new version rather than a cached one.
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: staged.path)
            do { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) } catch {
                throw AppFailure("无法替换现在的 Lilt，原来的版本未改动。")
            }
            try? FileManager.default.removeItem(at: folder)
            do { try Self.relaunch(target) } catch {
                throw AppFailure("新版本已装好，但没能自动重新打开。请退出后手动打开 Lilt。")
            }
            NSApp.terminate(nil)
            // Still here: the request was turned down, typically because an alert or sheet is on screen. The new copy
            // is already in place and every change is saved as it happens, so leave rather than run on beside it.
            exit(0)
        } catch {
            if let work { try? FileManager.default.removeItem(at: work) }
            phase = .failed(Self.message(error), release)
        }
    }

    /// Short work, such as a usage read, is waited for; anything still running after half a minute stops the update.
    private func waitUntilClear(_ blocker: () -> String?) async throws {
        for _ in 0..<60 {
            guard blocker() != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let reason = blocker() { throw AppFailure(reason) }
    }

    private var permissionBlocker: String? {
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: folder.path), manager.isWritableFile(atPath: target.path) else {
            return "没有权限替换“\(folder.lastPathComponent)”里的 Lilt，请到发布页手动下载"
        }
        return nil
    }

    // MARK: Network

    private nonisolated static var userAgent: String { "Lilt/\(AppBuild.version)" }

    private nonisolated static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout; config.urlCache = nil
        return URLSession(configuration: config, delegate: GitHubOnly(), delegateQueue: nil)
    }

    private nonisolated static func newest(after current: AppVersion) async throws -> UpdateRelease? {
        let session = session(timeout: 20)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: UpdateFeed.releases)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw AppFailure("连不上 GitHub，请检查网络后再试。") }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        // Unauthenticated GitHub API calls are limited per network address, shared with anything else on it.
        case 403, 429: throw AppFailure("GitHub 暂时限制了查询，请过一会儿再试。")
        default: throw AppFailure("GitHub 没有返回发布信息，请稍后再试。")
        }
        do { return try UpdateFeed.newest(in: data, after: current) } catch { throw AppFailure("看不懂 GitHub 返回的发布信息。") }
    }

    /// Streams the image to disk, refusing anything larger than the release says and checking GitHub's digest.
    private nonisolated static func download(_ release: UpdateRelease, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = session(timeout: 60)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: release.asset)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch { throw AppFailure("下载失败，请检查网络后再试。") }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("下载失败：GitHub 没有给出安装包。") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw AppFailure("无法保存下载的安装包。") }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written = 0
        func flush() throws {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            written += buffer.count
            buffer.removeAll(keepingCapacity: true)
            progress(min(1, Double(written) / Double(release.size)))
        }
        let tooLarge = AppFailure("安装包大小和发布信息不符，已放弃。")
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if written + buffer.count > release.size { throw tooLarge }
                if buffer.count >= 1 << 16 { try flush() }
            }
            try flush()
        } catch let failure as AppFailure { throw failure } catch { throw AppFailure("下载中断，请再试一次。") }
        guard written == release.size else { throw tooLarge }
        if let expected = release.sha256 {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw AppFailure("安装包校验不通过，已放弃。") }
        }
    }

    // MARK: Install

    /// Mounts the image read-only, copies the app out next to the download and checks it is the release it claims to be.
    private nonisolated static func stage(_ image: URL, in folder: URL, release: UpdateRelease) throws -> URL {
        let mount = folder.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        guard run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, "-quiet") else {
            throw AppFailure("无法打开下载的安装包。")
        }
        defer { _ = run("/usr/bin/hdiutil", "detach", mount.path, "-force", "-quiet") }
        let source = mount.appendingPathComponent("Lilt.app", isDirectory: true)
        let kind = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard kind?.isSymbolicLink == false, kind?.isDirectory == true else { throw AppFailure("安装包里没有 Lilt。") }
        let staged = folder.appendingPathComponent("Lilt.app", isDirectory: true)
        // ditto keeps the signature and extended attributes that a plain copy can drop.
        guard run("/usr/bin/ditto", source.path, staged.path) else { throw AppFailure("无法取出新版本。") }
        try verify(staged, release: release)
        return staged
    }

    private nonisolated static func verify(_ app: URL, release: UpdateRelease) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              UpdateFeed.matches(info: info, version: release.version) else {
            throw AppFailure("下载的不是 Lilt \(release.version)，已放弃。")
        }
        guard Bundle(url: app)?.executableArchitectures?.contains(where: { $0.intValue == architecture }) == true else {
            throw AppFailure("新版本不支持这台 Mac 的芯片。")
        }
        // Releases are ad-hoc signed, so this proves the bundle is whole and unchanged since it was signed, not who signed it.
        guard run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path) else { throw AppFailure("新版本的签名校验不通过，已放弃。") }
        // Downloads made here carry no quarantine flag. Clearing it anyway keeps a flagged copy from being refused at launch,
        // the same step the README gives for installing by hand.
        _ = run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path)
    }

    private nonisolated static var architecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Opens the new copy once this one has quit: a copy opened earlier would find this one still running and close itself.
    /// The paths travel as arguments, never inside the script text.
    private static func relaunch(_ app: URL) throws {
        // The update from 0.1.5 to 0.1.6 swapped the bundle and then left Lilt closed. Afterwards it could not be told
        // whether `open` found this copy still on record and only brought it forward, or the new copy closed itself
        // (see `AppDelegate.otherInstance`). `-n` covers the first: it always starts a new copy.
        var options = ["-n"]
        #if DEBUG
        // A trial install inside a fake home opens the new copy in that same home, never the real one.
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty {
            options += ["--env", "CFFIXED_USER_HOME=\(home)"]
        }
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"pid=$1; shift; i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open "$@""#,
                             "lilt-relaunch", String(ProcessInfo.processInfo.processIdentifier)] + options + [app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func message(_ error: Error) -> String {
        (error as? AppFailure)?.message ?? "更新没有完成，请稍后再试。"
    }

    #if DEBUG
    /// LILT_UPDATE=available|downloading|installing|failed|current shows that state with a fictional release, without the network.
    func preview(_ state: String) {
        let release = UpdateRelease(version: AppVersion("0.1.3")!, asset: URL(string: "https://github.com/example.invalid/Lilt-0.1.3.dmg")!, size: 1,
                                    sha256: nil, page: URL(string: "https://github.com/example.invalid")!, notes: "fixture")
        lastCheck = .now
        switch state {
        case "available": phase = .available(release)
        case "downloading": phase = .downloading(release, 0.42)
        case "installing": phase = .installing(release)
        case "failed": phase = .failed("下载中断，请再试一次。", release)
        case "current": phase = .current; reportsResult = true
        default: break
        }
    }
    #endif
}
