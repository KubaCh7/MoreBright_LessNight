import CoreGraphics
import Foundation
import QuartzCore
import os

/// Boost through the display's transfer table, the way BetterDisplay ("color table"),
/// Lunar and BrightIntosh do it by default.
///
/// While EDR is engaged (kept alive by a 1×1 trigger window), the display pipeline accepts
/// transfer-table values above 1.0. Scaling the current table by `k` gives, for a power-law
/// encoding, `(k·x)^γ = k^γ · x^γ`: a pure linear gain of `k^γ` on every channel. So hue and
/// white point stay put, and whatever the system already had in the table is preserved.
///
/// Unlike the full-screen multiply overlay, the table is applied in the display pipeline, so
/// window animations (⌘Tab, Space swipes, Mission Control) can't drop the boost.
/// macOS resets transfer tables when the process exits, so a crash leaves nothing behind.
final class GammaBoost {
    private static let tableSize: UInt32 = 256
    private static let gamma: Double = 2.2
    private static let rampDuration: CFTimeInterval = 0.2
    private static let driftTolerance: CGGammaValue = 0.003

    private let display: CGDirectDisplayID
    private let queue = DispatchQueue(label: "MoreBrightLessNight.gamma", qos: .userInteractive)

    // queue-confined
    private var base: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])?
    private var currentFactor: Float = 1
    private var targetFactor: Float = 1
    private var rampFrom: Float = 1
    private var rampStart: CFTimeInterval = 0
    private var rampTimer: DispatchSourceTimer?
    private var integrityTimer: DispatchSourceTimer?

    init(display: CGDirectDisplayID) {
        self.display = display
    }

    deinit {
        let display = display
        let base = base
        rampTimer?.cancel()
        integrityTimer?.cancel()
        if let base, currentFactor != 1 { Self.write(display, base, factor: 1) }
    }

    /// Main thread. `gain` is the linear gain wanted on screen.
    func setGain(_ gain: Double, animated: Bool) {
        let factor = Float(pow(max(1, gain), 1 / Self.gamma))
        queue.async { [self] in
            // Take a fresh copy of the system table every time a boost starts, so changes the
            // system made in between (ColorSync, display reconfiguration) are respected.
            if factor > 1.0001, currentFactor <= 1.0001 { captureBase() }
            guard base != nil else { return }
            targetFactor = factor
            if animated, abs(factor - currentFactor) > 0.001 {
                rampFrom = currentFactor
                rampStart = CACurrentMediaTime()
                startRamp()
            } else {
                stopRamp()
                apply(factor)
                settle()
            }
        }
    }

    /// Puts the original table back right away. Used on teardown and when switching technique.
    func restoreNow() {
        queue.sync {
            stopRamp()
            stopIntegrity()
            if currentFactor != 1 { apply(1) }
            targetFactor = 1
        }
    }

    // MARK: queue

    private func captureBase() {
        var r = [CGGammaValue](repeating: 0, count: Int(Self.tableSize))
        var g = r
        var b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, Self.tableSize, &r, &g, &b, &count) == .success, count > 1 else {
            overlayLog.error("display \(self.display) CGGetDisplayTransferByTable failed")
            base = nil
            return
        }
        let n = Int(count)
        base = (Array(r.prefix(n)), Array(g.prefix(n)), Array(b.prefix(n)))
    }

    private func apply(_ factor: Float) {
        guard let base else { return }
        if Self.write(display, base, factor: factor) {
            currentFactor = factor
        } else {
            overlayLog.error("display \(self.display) CGSetDisplayTransferByTable failed")
        }
    }

    @discardableResult
    private static func write(_ display: CGDirectDisplayID,
                              _ base: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue]),
                              factor: Float) -> Bool {
        var r = base.r.map { $0 * factor }
        var g = base.g.map { $0 * factor }
        var b = base.b.map { $0 * factor }
        return CGSetDisplayTransferByTable(display, UInt32(r.count), &r, &g, &b) == .success
    }

    private func startRamp() {
        guard rampTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.rampTick() }
        rampTimer = timer
        timer.resume()
    }

    private func stopRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    private func rampTick() {
        let progress = Float(min(1, (CACurrentMediaTime() - rampStart) / Self.rampDuration))
        let remaining = 1 - progress
        let eased = 1 - remaining * remaining * remaining // ease-out cubic
        apply(rampFrom + (targetFactor - rampFrom) * eased)
        if progress >= 1 {
            stopRamp()
            settle()
        }
    }

    private func settle() {
        if targetFactor > 1.0001 {
            startIntegrity()
        } else {
            stopIntegrity()
        }
    }

    /// Every 2 s: if someone replaced the table (ColorSync, display reconfiguration, another
    /// app), take the new table as the base and apply the boost on top again.
    private func startIntegrity() {
        guard integrityTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkIntegrity() }
        integrityTimer = timer
        timer.resume()
    }

    private func stopIntegrity() {
        integrityTimer?.cancel()
        integrityTimer = nil
    }

    private func checkIntegrity() {
        guard rampTimer == nil, let base, let expected = base.r.last.map({ $0 * currentFactor }) else { return }
        var r = [CGGammaValue](repeating: 0, count: Int(Self.tableSize))
        var g = r
        var b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, Self.tableSize, &r, &g, &b, &count) == .success, count > 1 else { return }
        let actual = r[Int(count) - 1]
        guard abs(actual - expected) > Self.driftTolerance else { return }
        overlayLog.info("display \(self.display) transfer table replaced (last \(actual, format: .fixed(precision: 3)), expected \(expected, format: .fixed(precision: 3))), re-applying")
        let n = Int(count)
        self.base = (Array(r.prefix(n)), Array(g.prefix(n)), Array(b.prefix(n)))
        apply(currentFactor)
    }
}
