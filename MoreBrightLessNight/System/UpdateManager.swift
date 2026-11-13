import AppKit
import CryptoKit
import Foundation

enum UpdateConfig {
    static let owner = "KubaCh7"
    static let repository = "MoreBright_LessNight"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
}

struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let numbers = text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int
    }

    let tagName: String
    let name: String?
    let htmlUrl: URL
    let assets: [Asset]

    var dmgAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case missingChecksum
    case checksumMismatch
    case noAppInImage
    case wrongApp
    case invalidSignature
    case translocated
    case notWritable
    case command(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return String(localized: "GitHub returned an error.") + " (HTTP \(code))"
        case .missingChecksum: return String(localized: "The release has no checksum file, so the update can't be verified.")
        case .checksumMismatch: return String(localized: "The download is damaged (checksum mismatch).")
        case .noAppInImage: return String(localized: "The disk image doesn't contain the app.")
        case .wrongApp: return String(localized: "The downloaded app is not MoreBrightLessNight.")
        case .invalidSignature: return String(localized: "The downloaded app's code signature is invalid.")
        case .translocated: return String(localized: "Move MoreBrightLessNight to the Applications folder to install updates.")
        case .notWritable: return String(localized: "MoreBrightLessNight can't replace itself in its current folder. Move it to the Applications folder.")
        case .command(let output): return output
        }
    }
}

/// Checks GitHub Releases for a newer version and installs it.
///
/// Verification before anything is replaced: HTTPS download from GitHub, SHA-256 against the
/// `.sha256` asset of the same release, bundle identifier match, and `codesign --verify --strict`.
/// The swap happens in a tiny shell process after this app quits, then the new version is opened.
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private enum Keys {
        static let automatic = "automaticUpdateChecks"
        static let lastChecked = "lastUpdateCheck"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published private(set) var availableRelease: GitHubRelease?
    @Published var automaticChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: Keys.automatic)
            scheduleChecks()
        }
    }

    let currentVersion: String

    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?
    private var didScheduleLaunchCheck = false

    init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        automaticChecks = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
        scheduleChecks()
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Checking

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard automaticChecks else { return }

        if !didScheduleLaunchCheck {
            didScheduleLaunchCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < UpdateConfig.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    @MainActor
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            var request = URLRequest(url: UpdateConfig.latestReleaseURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MoreBrightLessNight-Updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            markChecked()

            if status == 404 { // no published release yet
                availableRelease = nil
                state = .upToDate
                return
            }
            guard status == 200 else { throw UpdateError.http(status) }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)

            guard let latest = AppVersion(release.tagName),
                  let current = AppVersion(currentVersion),
                  latest > current,
                  release.dmgAsset != nil else {
                availableRelease = nil
                state = .upToDate
                return
            }
            availableRelease = release
            state = .available(latest.description)
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func markChecked() {
        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: Keys.lastChecked)
    }

    // MARK: Installing

    func installUpdate() {
        Task { await install() }
    }

    @MainActor
    private func install() async {
        guard let release = availableRelease, let dmg = release.dmgAsset, !isBusy else { return }
        do {
            let destination = Bundle.main.bundleURL
            try Self.checkInstallLocation(destination)
            guard let checksumAsset = release.asset(named: dmg.name + ".sha256") else {
                throw UpdateError.missingChecksum
            }
            let bundleID = Bundle.main.bundleIdentifier ?? ""

            state = .downloading(0)
            let expected = try await Self.fetchChecksum(checksumAsset.browserDownloadUrl)
            let image = try await download(dmg.browserDownloadUrl)
            progressObservation = nil

            state = .installing
            let staged = try await Task.detached(priority: .userInitiated) {
                try UpdateManager.verifyAndStage(image: image, expectedSHA256: expected, bundleID: bundleID)
            }.value

            try Self.launchReplacer(newApp: staged, destination: destination)
            NSApp.terminate(nil)
        } catch {
            progressObservation = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let temporary, status == 200 else {
                    continuation.resume(throwing: UpdateError.http(status))
                    return
                }
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MoreBrightLessNight-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: temporary, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async {
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
            task.resume()
        }
    }

    private static func fetchChecksum(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let token = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first.map(String.init)?.lowercased() ?? ""
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { throw UpdateError.missingChecksum }
        return token
    }

    private static func checkInstallLocation(_ app: URL) throws {
        if app.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: app.path) else { throw UpdateError.notWritable }
    }

    /// Runs off the main thread.
    private static func verifyAndStage(image: URL, expectedSHA256: String, bundleID: String) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: image) }

        let digest = SHA256.hash(data: try Data(contentsOf: image, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else { throw UpdateError.checksumMismatch }

        let work = fm.temporaryDirectory.appendingPathComponent("MoreBrightLessNight-update-\(UUID().uuidString)")
        let mountPoint = work.appendingPathComponent("mount")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mountPoint.path, image.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path]) }

        guard let app = try fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInImage }
        guard Bundle(url: app)?.bundleIdentifier == bundleID else { throw UpdateError.wrongApp }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.invalidSignature
        }

        let staged = work.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Waits for this process to exit, swaps the bundle (with rollback), relaunches.
    private static func launchReplacer(newApp: URL, destination: URL) throws {
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old"; then
          if /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        rm -rf "$(dirname "$NEW")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "mbln-updater",
                             String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path]
        try process.run()
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.command("\((path as NSString).lastPathComponent): \(output)")
        }
        return output
    }
}
