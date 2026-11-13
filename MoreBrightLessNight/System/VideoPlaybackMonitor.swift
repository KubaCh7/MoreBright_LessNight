import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import os

/// Detects video playback, so the boost can step aside: HDR video already uses the EDR
/// headroom, and a boosted transfer table would blow its highlights out.
///
/// macOS has no public "HDR content is on screen" signal. What players and browsers do
/// reliably is hold a display-sleep power assertion while video plays (Safari/WebKit,
/// Chrome "Video Wake Lock", TV, QuickTime, IINA, VLC...). We read those with the public
/// `IOPMCopyAssertionsByProcess`, every 2 s, read-only. SDR video counts too: the
/// assertion doesn't say whether the video is HDR.
final class VideoPlaybackMonitor {
    private(set) var isPlayingVideo = false
    var onChange: (() -> Void)?

    private var timer: Timer?

    private static let displaySleepTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    private static let videoAppPrefixes = [
        "com.apple.WebKit", "com.apple.Safari", "com.apple.TV", "com.apple.QuickTimePlayerX",
        "com.apple.Photos", "com.google.Chrome", "company.thebrowser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware", "com.vivaldi",
        "com.colliderli.iina", "org.videolan.vlc", "io.mpv", "com.firecore.infuse",
        "tv.plex", "com.plexapp", "com.netflix", "com.disney",
    ]

    private static let videoPathMarkers = [
        "WebKit", "Google Chrome", "Chromium", "Arc.app", "Firefox", "Microsoft Edge",
        "Brave Browser", "Opera", "Vivaldi", "IINA", "VLC", "Infuse", "Plex",
    ]

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isPlayingVideo {
            isPlayingVideo = false
            onChange?()
        }
    }

    private func poll() {
        let playing = Self.videoAssertionPresent()
        guard playing != isPlayingVideo else { return }
        isPlayingVideo = playing
        overlayLog.info("video playback \(playing ? "started" : "stopped", privacy: .public)")
        onChange?()
    }

    private static func videoAssertionPresent() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as NSDictionary? else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for (key, value) in byPID {
            guard let pid = (key as? NSNumber)?.int32Value, pid != ownPID,
                  let assertions = value as? [[String: Any]] else { continue }
            let displaySleep = assertions.filter { displaySleepTypes.contains($0["AssertType"] as? String ?? "") }
            guard !displaySleep.isEmpty else { continue }

            if displaySleep.contains(where: { ($0["AssertName"] as? String ?? "").localizedCaseInsensitiveContains("video") }) {
                return true
            }
            if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               videoAppPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
            // Helper / XPC processes (WebKit GPU process, browser helpers) aren't apps.
            if let path = executablePath(pid), videoPathMarkers.contains(where: { path.contains($0) }) {
                return true
            }
        }
        return false
    }
}
