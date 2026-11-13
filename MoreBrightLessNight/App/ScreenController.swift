import AppKit
import Combine

enum PauseReason: Equatable {
    case thermal, screensAsleep, lowBattery, onBattery

    var title: String {
        switch self {
        case .thermal: return String(localized: "Paused: thermal limit")
        case .screensAsleep: return String(localized: "Paused: display asleep")
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
final class ScreenController: ObservableObject, Identifiable {
    let displayID: CGDirectDisplayID
    let key: String
    var id: CGDirectDisplayID { displayID }

    @Published private(set) var name: String
    @Published private(set) var potentialHeadroom: Double
    @Published private(set) var currentHeadroom: Double
    @Published private(set) var systemBrightness: Double?
    @Published private(set) var boostGain: Double
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
    private var lastOwnWrite: Date = .distantPast
    private var headroomTimer: Timer?
    private var overlayActiveSince: Date?
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

        observation = BrightnessObservation(display: displayID) { [weak self] value in
            self?.handleBrightnessChange(value)
        }
        clampBoostToMode()
    }

    deinit { tearDown() }

    func tearDown() {
        observation?.invalidate()
        observation = nil
        pendingWrite?.cancel()
        headroomTimer?.invalidate()
        headroomTimer = nil
        overlay?.tearDown()
        overlay = nil
    }

    // MARK: Derived state

    var supportsEDR: Bool { potentialHeadroom > 1.0 }
    var controlsSystemBrightness: Bool { canWriteBrightness && systemBrightness != nil }

    /// Highest gain the slider can reach in the current mode, never above real headroom.
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
        return (boostGain - 1) / (top - 1)
    }

    /// What the overlay is actually asked to do right now.
    var effectiveGain: Double {
        if let overrideGain { return overrideGain }
        return requestedGain
    }

    private var requestedGain: Double {
        guard supportsEDR, model?.pauseReason == nil else { return 1 }
        if controlsSystemBrightness, (systemBrightness ?? 1) < 0.995 { return 1 }
        return min(boostGain, maxGain)
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
        clampBoostToMode()
        applyOverlay(animated: true)
    }

    func setOverlayCaptureVisible(_ visible: Bool) {
        overlay?.setCaptureVisible(visible)
    }

    // MARK: Model callbacks

    func update(screen: NSScreen) {
        self.screen = screen
        name = screen.localizedName
        refreshHeadroom()
        overlay?.updateFrame(for: screen)
        clampBoostToMode()
        applyOverlay(animated: true)
    }

    /// Peak mode toggled. The stored gain (i.e. nits) is kept; only the percentages move.
    func modeDidChange() {
        clampBoostToMode()
        objectWillChange.send()
        applyOverlay(animated: true)
    }

    func applyOverlay(animated: Bool) {
        let gain = effectiveGain
        if gain > 1.0001 {
            if overlay == nil { overlay = EDROverlay(screen: screen) }
            overlay?.setGain(gain, animated: animated)
            if overlayActiveSince == nil { overlayActiveSince = Date() }
            startHeadroomMonitor()
        } else {
            overlay?.setGain(1, animated: animated)
            overlayActiveSince = nil
            stopHeadroomMonitor()
            if highlightsClipped { highlightsClipped = false }
        }
    }

    // MARK: Private

    private func clampBoostToMode() {
        let clamped = min(max(boostGain, 1), maxGain)
        if clamped != boostGain {
            boostGain = clamped
            defaults.set(boostGain, forKey: "boost.\(key)")
        }
    }

    /// Coalesced to ≤ 30 writes/s while dragging. Only ever called from a user action.
    private func writeBrightness(_ value: Double) {
        guard controlsSystemBrightness else { return }
        if let current = systemBrightness, abs(current - value) < 0.002 { return }
        systemBrightness = value
        pendingBrightness = value
        lastOwnWrite = Date()
        guard pendingWrite == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let value = self.pendingBrightness else { return }
            self.pendingWrite = nil
            self.pendingBrightness = nil
            DisplayServices.setBrightness(self.displayID, value)
            self.observation?.noteOwnWrite(value)
            self.lastOwnWrite = Date()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: work)
    }

    /// Someone else changed brightness (F1/F2, Control Center, auto-brightness...).
    /// We follow it. We never write back or "correct" it.
    private func handleBrightnessChange(_ value: Double) {
        if pendingWrite != nil || Date().timeIntervalSince(lastOwnWrite) < 1.0 { return } // our own echo
        systemBrightness = value
        if value < 0.995, boostGain > 1 {
            boostGain = 1
            defaults.set(boostGain, forKey: "boost.\(key)")
        }
        applyOverlay(animated: true)
    }

    private func refreshHeadroom() {
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        if potential != potentialHeadroom { potentialHeadroom = potential }
        if current != currentHeadroom { currentHeadroom = current }

        // macOS raises the current headroom lazily after EDR content appears; give it time.
        let gain = effectiveGain
        if gain > 1.0001, let since = overlayActiveSince, Date().timeIntervalSince(since) > 1.5 {
            let clipped = current + 0.02 < gain
            if clipped != highlightsClipped { highlightsClipped = clipped }
        }
    }

    private func startHeadroomMonitor() {
        guard headroomTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshHeadroom() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        headroomTimer = timer
    }

    private func stopHeadroomMonitor() {
        headroomTimer?.invalidate()
        headroomTimer = nil
    }
}
