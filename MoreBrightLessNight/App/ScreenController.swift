import AppKit
import Combine
import os

enum PauseReason: Equatable {
    case thermal, screensAsleep, lowBattery, onBattery, videoPlaying

    var title: String {
        switch self {
        case .thermal: return String(localized: "Paused: thermal limit")
        case .screensAsleep: return String(localized: "Paused: display asleep or locked")
        case .lowBattery: return String(localized: "Paused: low battery")
        case .onBattery: return String(localized: "Paused: on battery power")
        case .videoPlaying: return String(localized: "Paused: video playing")
        }
    }

    var symbol: String {
        switch self {
        case .thermal: return "thermometer.sun.fill"
        case .screensAsleep: return "moon.zzz.fill"
        case .lowBattery: return "battery.25percent"
        case .onBattery: return "powerplug"
        case .videoPlaying: return "play.rectangle.fill"
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

/// How bright "100 % macOS brightness" should be.
enum BoostLevel: String, CaseIterable, Identifiable {
    case off, sustained, peak
    var id: String { rawValue }

    func maxNits(_ profile: NitsProfile) -> Double {
        switch self {
        case .off: return profile.sdrNits
        case .sustained: return profile.sustainedNits
        case .peak: return profile.peakNits
        }
    }
}

/// How the boost is produced.
enum BoostTechnique: String, CaseIterable, Identifiable {
    /// Transfer table × gain, EDR kept alive by a 1×1 trigger. Survives ⌘Tab / Space swipes.
    case gammaTable
    /// Full-screen multiply-composited EDR overlay.
    case overlay
    var id: String { rawValue }
}

/// One physical display.
///
/// Brightness model: "100 % macOS = 100 % of the chosen maximum".
/// The slider and the brightness keys control macOS brightness exactly as usual. While a
/// boost level is selected, the overlay multiplies the whole image by a constant gain =
/// max nits / SDR nits (2× for 1000 nits, 3.2× for 1600 nits on a MacBook Pro XDR), so
/// macOS 100 % becomes the chosen maximum and every lower step scales with it. Keys,
/// auto-brightness and Control Center keep working natively; nothing is written back.
///
/// Displays whose brightness macOS can't control (some external EDR monitors) get a slider
/// that sets the overlay strength instead.
final class ScreenController: ObservableObject, Identifiable {
    let displayID: CGDirectDisplayID
    let key: String
    var id: CGDirectDisplayID { displayID }

    @Published private(set) var name: String
    @Published private(set) var potentialHeadroom: Double
    @Published private(set) var currentHeadroom: Double
    @Published private(set) var systemBrightness: Double?
    /// Overlay strength 0...1 for displays without macOS brightness control.
    @Published private(set) var overlayFraction: Double
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
    private var trigger: EDROverlay?
    private lazy var gamma = GammaBoost(display: displayID)
    private var observation: BrightnessObservation?
    private let canWriteBrightness: Bool
    private var pendingBrightness: Double?
    private var pendingWrite: DispatchWorkItem?
    private var lastObservedBrightness: Double?
    /// Value we last asked macOS for; macOS animates toward it, those samples are our echo.
    private var ownTarget: Double?
    private var ownTargetDeadline: Date = .distantPast
    private var boostRequestedSince: Date?
    private var fastPollUntil: Date = .distantPast
    private var headroomTimer: Timer?
    private var headroomTimerInterval: TimeInterval = 0
    /// Headroom we follow. Rises immediately; drops only after a dip lasts `dipGrace`, so
    /// short transient dips (Cmd+Tab, Space switch, Mission Control animations) don't dim.
    private var stableHeadroom: Double = 1
    private var headroomDipSince: Date?
    private static let dipGrace: TimeInterval = 3
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
        overlayFraction = UserDefaults.standard.object(forKey: "overlayFraction.\(key)") as? Double ?? 1
        lastObservedBrightness = systemBrightness

        // 0.2.0 paused auto-brightness while boosting. If that state was left behind, undo it.
        let legacyKey = "autoBrightnessPaused.\(key)"
        if UserDefaults.standard.bool(forKey: legacyKey) {
            DisplayServices.setAutoBrightness(displayID, enabled: true)
            UserDefaults.standard.removeObject(forKey: legacyKey)
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
        overlay?.tearDown()
        overlay = nil
        trigger?.tearDown()
        trigger = nil
        gamma.restoreNow()
    }

    // MARK: Derived state

    var supportsEDR: Bool { potentialHeadroom > 1.0 }
    var controlsSystemBrightness: Bool { canWriteBrightness && systemBrightness != nil }
    var boostLevel: BoostLevel { model?.boostLevel ?? .off }

    /// Gain that turns macOS 100 % into the chosen maximum, never above potential headroom.
    var maxGain: Double {
        guard supportsEDR else { return 1 }
        return max(1, min(boostLevel.maxNits(profile) / profile.sdrNits, potentialHeadroom))
    }

    /// Nits that 100 % on the slider means right now.
    var fullScaleNits: Double { profile.sdrNits * maxGain }

    var position: Double {
        if controlsSystemBrightness { return systemBrightness ?? 1 }
        return overlayFraction
    }

    /// Gain the current mode asks for (capped by pause reasons, not by live headroom).
    var requestedGain: Double {
        guard supportsEDR, boostLevel != .off, model?.pauseReason == nil else { return 1 }
        if controlsSystemBrightness { return maxGain }
        return 1 + overlayFraction * (maxGain - 1)
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
        if stableHeadroom >= 1.05 { return stableHeadroom }
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

    private var technique: BoostTechnique { model?.technique ?? .gammaTable }
    private var edrWindow: EDROverlay? { technique == .gammaTable ? trigger : overlay }
    var overlayIsPresenting: Bool { edrWindow?.isPresenting ?? false }
    var secondsSinceLastFrame: Double? { edrWindow?.secondsSinceLastFrame }

    // MARK: User actions

    func setPosition(_ newValue: Double) {
        let p = min(max(newValue, 0), 1)
        if controlsSystemBrightness {
            writeBrightness(p)
        } else {
            overlayFraction = p
            defaults.set(p, forKey: "overlayFraction.\(key)")
            applyOverlay(animated: true)
        }
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
        trigger?.updateFrame(for: screen)
        refreshHeadroom()
        applyOverlay(animated: true)
    }

    /// Boost level changed.
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
                stableHeadroom = currentHeadroom
                headroomDipSince = nil
            }
            startHeadroomMonitor()
        } else {
            boostRequestedSince = nil
            stopHeadroomMonitor()
            if highlightsClipped { highlightsClipped = false }
        }

        let gain = effectiveGain
        switch technique {
        case .gammaTable:
            overlay?.setGain(1, animated: false)
            if gain > 1.0001 {
                if trigger == nil { trigger = EDROverlay(screen: screen, mode: .trigger) }
                trigger?.setGain(Self.triggerValue, animated: false)
                gamma.setGain(gain, animated: animated)
            } else {
                gamma.setGain(1, animated: animated)
                trigger?.setGain(1, animated: false)
            }
        case .overlay:
            gamma.setGain(1, animated: false)
            trigger?.setGain(1, animated: false)
            if gain > 1.0001 {
                if overlay == nil { overlay = EDROverlay(screen: screen) }
                overlay?.setGain(gain, animated: animated)
            } else {
                overlay?.setGain(1, animated: animated)
            }
        }
        if abs(gain - appliedGain) > 0.005 {
            overlayLog.info("display \(self.displayID) gain \(self.appliedGain, format: .fixed(precision: 2)) -> \(gain, format: .fixed(precision: 2)) (requested \(self.requestedGain, format: .fixed(precision: 2)), headroom \(self.currentHeadroom, format: .fixed(precision: 2)))")
            appliedGain = gain
        }
    }

    /// App switch, Space change: make sure the overlay is still on top and poll fast for a bit.
    func reassertOverlay() {
        guard overlayIsPresenting else { return }
        edrWindow?.orderFront()
        fastPollUntil = max(fastPollUntil, Date().addingTimeInterval(5))
        startHeadroomMonitor()
    }

    // MARK: Private

    /// EDR value the 1×1 trigger shows (BrightIntosh uses 1.6). It only has to be above 1.0
    /// for macOS to grant headroom; the transfer table does the actual boost.
    private static let triggerValue = 1.6

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

    /// Brightness keys, Control Center, auto-brightness or our own slider. We only follow it.
    private func handleBrightnessChange(_ value: Double) {
        let previous = lastObservedBrightness ?? value
        lastObservedBrightness = value

        // While our own write is in flight / macOS animates toward it, keep the slider still.
        if pendingWrite != nil { return }
        if let target = ownTarget {
            if abs(value - target) <= 0.01 {
                ownTarget = nil
            } else if Date() < ownTargetDeadline,
                      abs(value - target) < abs(previous - target) - 0.001 || abs(value - previous) < 0.001 {
                return
            } else {
                ownTarget = nil
            }
        }
        if systemBrightness != value { systemBrightness = value }
    }

    private func refreshHeadroom() {
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let changed = abs(current - currentHeadroom) > 0.01 || abs(potential - potentialHeadroom) > 0.01
        if potential != potentialHeadroom { potentialHeadroom = potential }
        if current != currentHeadroom { currentHeadroom = current }

        var stableChanged = false
        if current >= stableHeadroom - 0.01 {
            if abs(current - stableHeadroom) > 0.01 { stableChanged = true }
            stableHeadroom = current
            headroomDipSince = nil
        } else if let since = headroomDipSince {
            if Date().timeIntervalSince(since) >= Self.dipGrace {
                overlayLog.info("display \(self.displayID) headroom dip persisted, following \(self.stableHeadroom, format: .fixed(precision: 2)) -> \(current, format: .fixed(precision: 2))")
                stableHeadroom = current
                headroomDipSince = nil
                stableChanged = true
            }
        } else {
            headroomDipSince = Date()
            overlayLog.debug("display \(self.displayID) headroom dip \(current, format: .fixed(precision: 2)) (holding \(self.stableHeadroom, format: .fixed(precision: 2)))")
        }

        let requested = requestedGain
        if requested > 1.0001, let since = boostRequestedSince, Date().timeIntervalSince(since) > 1.5 {
            let clipped = current + 0.02 < requested
            if clipped != highlightsClipped { highlightsClipped = clipped }
        }

        if changed || stableChanged {
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
