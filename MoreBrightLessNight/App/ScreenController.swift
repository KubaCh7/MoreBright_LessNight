import AppKit
import Combine
import os

enum PauseReason: Equatable {
    case thermal, screensAsleep, lowBattery, onBattery

    var title: String {
        switch self {
        case .thermal: return String(localized: "Paused: thermal limit")
        case .screensAsleep: return String(localized: "Paused: display asleep or locked")
        case .lowBattery: return String(localized: "Paused: low battery")
        case .onBattery: return String(localized: "Paused: on battery power")
        }
    }

    var symbol: String {
        switch self {
        case .thermal: return "thermometer.sun.fill"
        case .screensAsleep: return "moon.zzz.fill"
        case .lowBattery: return "battery.25percent"
        case .onBattery: return "powerplug"
        }
    }
}

enum ScreenStatus: Equatable {
    case fullPower, thermallyLimited, unsupported, paused(PauseReason)

    var title: String {
        switch self {
        case .fullPower: return String(localized: "Full power")
        case .thermallyLimited: return String(localized: "Thermally limited")
        case .unsupported: return String(localized: "Unsupported display")
        case .paused(let reason): return reason.title
        }
    }

    var symbol: String {
        switch self {
        case .fullPower: return "checkmark.circle.fill"
        case .thermallyLimited: return "thermometer.sun.fill"
        case .unsupported: return "nosign"
        case .paused(let reason): return reason.symbol
        }
    }
}

/// One physical display: its EDR headroom, system brightness, requested boost and overlay.
///
/// Slider model (position p in 0...1, top = max gain for the current mode):
///   knee = 1 / top                          (the point that equals the system maximum)
///   p <= knee: system brightness = p / knee, gain = 1
///   p >  knee: system brightness = 1,        gain = p / knee  (linear in nits up to top)
/// Both sides meet at p == knee with brightness 1 and gain 1, so there is no jump.
///
/// `boostGain` is only ever the user's request. Everything else (mode, headroom, pause
/// reasons) is applied as a cap when computing `effectiveGain`, never written back, so a
/// momentary bad reading can't permanently reset the boost.
final class ScreenController: ObservableObject, Identifiable {
    let displayID: CGDirectDisplayID
    let key: String
    var id: CGDirectDisplayID { displayID }

    @Published private(set) var name: String
    @Published private(set) var potentialHeadroom: Double
    @Published private(set) var currentHeadroom: Double
    @Published private(set) var systemBrightness: Double?
    @Published private(set) var boostGain: Double
    @Published private(set) var appliedGain: Double = 1
    @Published private(set) var highlightsClipped = false
    @Published private(set) var profile: NitsProfile

    /// Used by the color test to force a gain temporarily.
    var overrideGain: Double? {
        didSet { applyOverlay(animated: false) }
    }

    weak var model: AppModel?

    private var screen: NSScreen
    private var overlay: EDROverlay?
    private var observation: BrightnessObservation?
    private let canWriteBrightness: Bool
    private var pendingBrightness: Double?
    private var pendingWrite: DispatchWorkItem?
    /// Last value macOS actually reported (never optimistic).
    private var lastObservedBrightness: Double?
    /// Value we last asked macOS for. macOS animates brightness changes, so for a moment it
    /// reports intermediate values; those are our own echo, not the user pressing F1.
    private var ownTarget: Double?
    private var ownTargetDeadline: Date = .distantPast
    private var boostRequestedSince: Date?
    private var fastPollUntil: Date = .distantPast
    private var headroomTimer: Timer?
    private var headroomTimerInterval: TimeInterval = 0
    private var autoBrightnessPaused = false
    private let defaults = UserDefaults.standard

    init(screen: NSScreen, displayID: CGDirectDisplayID, model: AppModel) {
        self.screen = screen
        self.displayID = displayID
        self.model = model
        key = persistentKey(for: displayID)
        name = screen.localizedName
        potentialHeadroom = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        currentHeadroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        systemBrightness = DisplayServices.brightness(displayID)
        canWriteBrightness = DisplayServices.canChangeBrightness(displayID)

        if let data = UserDefaults.standard.data(forKey: "profile.\(key)"),
           let saved = try? JSONDecoder().decode(NitsProfile.self, from: data) {
            profile = saved.sanitized
        } else {
            profile = .xdrDefault
        }
        let savedGain = UserDefaults.standard.double(forKey: "boost.\(key)")
        boostGain = savedGain >= 1 ? savedGain : 1
        lastObservedBrightness = systemBrightness

        // If we crashed while auto-brightness was paused, give it back now.
        if UserDefaults.standard.bool(forKey: Self.autoBrightnessKey(key)) {
            DisplayServices.setAutoBrightness(displayID, enabled: true)
            UserDefaults.standard.removeObject(forKey: Self.autoBrightnessKey(key))
        }

        observation = BrightnessObservation(display: displayID) { [weak self] value in
            self?.handleBrightnessChange(value)
        }
    }

    deinit { tearDown() }

    func tearDown() {
        observation?.invalidate()
        observation = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        stopHeadroomMonitor()
        restoreAutoBrightness()
        overlay?.tearDown()
        overlay = nil
    }

    private static func autoBrightnessKey(_ key: String) -> String { "autoBrightnessPaused.\(key)" }

    // MARK: Derived state

    var supportsEDR: Bool { potentialHeadroom > 1.0 }
    var controlsSystemBrightness: Bool { canWriteBrightness && systemBrightness != nil }

    /// Highest gain the slider can reach in the current mode, never above potential headroom.
    var maxGain: Double {
        guard supportsEDR else { return 1 }
        let peak = model?.peakModeEnabled ?? false
        let topNits = peak ? profile.peakNits : profile.sustainedNits
        return max(1, min(topNits / profile.sdrNits, potentialHeadroom))
    }

    /// Slider position where the EDR range starts (0...1).
    var knee: Double {
        guard controlsSystemBrightness else { return 0 }
        return 1 / maxGain
    }

    var position: Double {
        let top = maxGain
        if controlsSystemBrightness {
            if boostGain > 1.0001, top > 1 { return min(1, boostGain / top) }
            return (systemBrightness ?? 1) * knee
        }
        guard top > 1 else { return 0 }
        return min(1, (boostGain - 1) / (top - 1))
    }

    /// What the user asked for, capped by mode and pause reasons (not by live headroom).
    var requestedGain: Double {
        guard supportsEDR, model?.pauseReason == nil else { return 1 }
        if controlsSystemBrightness, (lastObservedBrightness ?? 1) < 0.9 { return 1 }
        return min(boostGain, maxGain)
    }

    /// What the overlay is asked to render right now.
    var effectiveGain: Double {
        if let overrideGain { return overrideGain }
        let requested = requestedGain
        guard requested > 1.0001 else { return 1 }
        return min(requested, availableHeadroom)
    }

    /// Headroom macOS grants right now. EDR engages lazily: until it does, a small wake-up
    /// gain asks for it (BrightIntosh uses 1.12). After sleep/wake macOS can report a bogus
    /// 1.0 for a long time; then fall back to the potential value (BetterDisplay #4918).
    private var availableHeadroom: Double {
        if currentHeadroom >= 1.05 { return currentHeadroom }
        if let since = boostRequestedSince, Date().timeIntervalSince(since) > 5 { return potentialHeadroom }
        return 1.12
    }

    var status: ScreenStatus {
        guard supportsEDR else { return .unsupported }
        if let reason = model?.pauseReason {
            return reason == .thermal ? .thermallyLimited : .paused(reason)
        }
        let thermal = model?.thermalState ?? .nominal
        if thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue, highlightsClipped {
            return .thermallyLimited
        }
        return .fullPower
    }

    // MARK: Diagnostics

    var overlayIsPresenting: Bool { overlay?.isPresenting ?? false }
    var secondsSinceLastFrame: Double? { overlay?.secondsSinceLastFrame }

    // MARK: User actions

    func setPosition(_ newValue: Double) {
        let p = min(max(newValue, 0), 1)
        let top = maxGain
        if controlsSystemBrightness {
            let k = knee
            writeBrightness(k > 0 ? min(1, p / k) : 1)
            boostGain = top > 1 ? max(1, min(top, p / k)) : 1
        } else {
            boostGain = 1 + p * (top - 1)
        }
        defaults.set(boostGain, forKey: "boost.\(key)")
        applyOverlay(animated: true)
    }

    func updateProfile(_ newProfile: NitsProfile) {
        profile = newProfile.sanitized
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: "profile.\(key)")
        }
        applyOverlay(animated: true)
    }

    func setOverlayCaptureVisible(_ visible: Bool) {
        overlay?.setCaptureVisible(visible)
    }

    // MARK: Model callbacks

    func update(screen: NSScreen) {
        self.screen = screen
        if name != screen.localizedName { name = screen.localizedName }
        if boostRequestedSince != nil { fastPollUntil = Date().addingTimeInterval(30) }
        overlay?.updateFrame(for: screen)
        refreshHeadroom()
        applyOverlay(animated: true)
    }

    /// Peak mode toggled. The stored gain (i.e. nits) is kept; only the percentages move.
    func modeDidChange() {
        objectWillChange.send()
        applyOverlay(animated: true)
    }

    func applyOverlay(animated: Bool) {
        let boosting = requestedGain > 1.0001 || (overrideGain ?? 1) > 1.0001
        if boosting {
            if boostRequestedSince == nil {
                boostRequestedSince = Date()
                fastPollUntil = Date().addingTimeInterval(30)
            }
            pauseAutoBrightnessIfNeeded()
            startHeadroomMonitor()
        } else {
            boostRequestedSince = nil
            stopHeadroomMonitor()
            restoreAutoBrightness()
            if highlightsClipped { highlightsClipped = false }
        }

        let gain = effectiveGain
        if gain > 1.0001 {
            if overlay == nil { overlay = EDROverlay(screen: screen) }
            overlay?.setGain(gain, animated: animated)
        } else {
            overlay?.setGain(1, animated: animated)
        }
        if abs(gain - appliedGain) > 0.005 {
            overlayLog.info("display \(self.displayID) gain \(self.appliedGain, format: .fixed(precision: 2)) -> \(gain, format: .fixed(precision: 2)) (requested \(self.requestedGain, format: .fixed(precision: 2)), headroom \(self.currentHeadroom, format: .fixed(precision: 2)))")
            appliedGain = gain
        }
    }

    /// Setting toggled off, or app quitting.
    func restoreAutoBrightness() {
        guard autoBrightnessPaused else { return }
        DisplayServices.setAutoBrightness(displayID, enabled: true)
        autoBrightnessPaused = false
        defaults.removeObject(forKey: Self.autoBrightnessKey(key))
        overlayLog.info("display \(self.displayID) auto-brightness restored")
    }

    // MARK: Private

    /// Auto-brightness pulls brightness down under a boost; BetterDisplay and Lunar pause it.
    private func pauseAutoBrightnessIfNeeded() {
        guard !autoBrightnessPaused, model?.pauseAutoBrightness ?? false,
              DisplayServices.autoBrightnessEnabled(displayID) == true else { return }
        DisplayServices.setAutoBrightness(displayID, enabled: false)
        autoBrightnessPaused = true
        defaults.set(true, forKey: Self.autoBrightnessKey(key))
        overlayLog.info("display \(self.displayID) auto-brightness paused")
    }

    /// Coalesced to ≤ 30 writes/s while dragging. Only ever called from a user action.
    private func writeBrightness(_ value: Double) {
        guard controlsSystemBrightness else { return }
        if let current = systemBrightness, abs(current - value) < 0.002 { return }
        systemBrightness = value
        pendingBrightness = value
        expectOwnBrightness(value)
        guard pendingWrite == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let value = self.pendingBrightness else { return }
            self.pendingWrite = nil
            self.pendingBrightness = nil
            DisplayServices.setBrightness(self.displayID, value)
            self.expectOwnBrightness(value)
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: work)
    }

    private func expectOwnBrightness(_ value: Double) {
        ownTarget = value
        ownTargetDeadline = Date().addingTimeInterval(3)
    }

    /// Someone (or our own animated write) changed brightness. We follow, never write back.
    private func handleBrightnessChange(_ value: Double) {
        let previous = lastObservedBrightness ?? value
        lastObservedBrightness = value
        defer { applyOverlay(animated: true) }

        // Our own write still in flight or still animating: not user input.
        if pendingWrite != nil { return }
        if let target = ownTarget {
            let reached = abs(value - target) <= 0.01
            if !reached, Date() < ownTargetDeadline { return }
            ownTarget = nil
            if reached {
                systemBrightness = value
                return
            }
        }

        systemBrightness = value
        // A real step down (one F1 press is 1/16) means the user wants it darker: drop the boost.
        if boostGain > 1, value < 0.995, previous - value >= 0.04 {
            overlayLog.info("display \(self.displayID) brightness stepped down \(previous, format: .fixed(precision: 3)) -> \(value, format: .fixed(precision: 3)), boost off")
            boostGain = 1
            defaults.set(boostGain, forKey: "boost.\(key)")
        }
    }

    private func refreshHeadroom() {
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let changed = abs(current - currentHeadroom) > 0.01 || abs(potential - potentialHeadroom) > 0.01
        if potential != potentialHeadroom { potentialHeadroom = potential }
        if current != currentHeadroom { currentHeadroom = current }

        let requested = requestedGain
        if requested > 1.0001, let since = boostRequestedSince, Date().timeIntervalSince(since) > 1.5 {
            let clipped = current + 0.02 < requested
            if clipped != highlightsClipped { highlightsClipped = clipped }
        }

        if changed {
            overlayLog.debug("display \(self.displayID) headroom current \(current, format: .fixed(precision: 2)) potential \(potential, format: .fixed(precision: 2))")
            applyOverlay(animated: true)
        }
        if headroomTimer != nil { startHeadroomMonitor() } // drop to the slow rate after the fast window
    }

    /// 10 Hz for 30 s after a boost starts or the screen changes, 2 Hz otherwise.
    private func startHeadroomMonitor() {
        let interval: TimeInterval = Date() < fastPollUntil ? 0.1 : 0.5
        if let headroomTimer, headroomTimer.isValid, headroomTimerInterval == interval { return }
        headroomTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refreshHeadroom() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        headroomTimer = timer
        headroomTimerInterval = interval
    }

    private func stopHeadroomMonitor() {
        headroomTimer?.invalidate()
        headroomTimer = nil
        headroomTimerInterval = 0
    }
}
