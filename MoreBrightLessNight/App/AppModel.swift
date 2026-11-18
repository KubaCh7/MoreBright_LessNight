import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Most recent automatic pause, shown in Settings so a sudden dim can be explained.
struct PauseEvent {
    let reason: PauseReason
    let date: Date
}

/// App-wide state. Main-thread only.
final class AppModel: ObservableObject {
    private enum Keys {
        static let peakMode = "peakModeEnabled"
        static let peakAcknowledged = "peakWarningAcknowledged"
        static let onlyOnAC = "onlyOnACPower"
        static let hotKey = "hotKeyChoice"
        static let boostLevel = "boostLevel"
        static let technique = "boostTechnique"
        static let pauseForVideo = "pauseForVideo"
        static let lastBoostLevel = "lastBoostLevel"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleKind = "scheduleKind"
        static let dayLevel = "scheduleDayLevel"
        static let nightLevel = "scheduleNightLevel"
        static let dayStart = "scheduleDayStartMinutes"
        static let nightStart = "scheduleNightStartMinutes"
        static let lastPeriod = "scheduleLastPeriod"
        static let appRules = "appRules"
    }

    @Published private(set) var screens: [ScreenController] = []
    @Published private(set) var boostLevel: BoostLevel

    /// Step aside while video plays, so HDR video isn't blown out by the boost.
    @Published var pauseForVideo: Bool {
        didSet {
            defaults.set(pauseForVideo, forKey: Keys.pauseForVideo)
            if pauseForVideo { video.start() } else { video.stop() }
            reevaluate()
        }
    }

    @Published var technique: BoostTechnique {
        didSet {
            defaults.set(technique.rawValue, forKey: Keys.technique)
            overlayLog.info("technique \(self.technique.rawValue, privacy: .public)")
            screens.forEach { $0.modeDidChange() }
        }
    }
    @Published private(set) var pauseReason: PauseReason?
    @Published private(set) var lastPause: PauseEvent?

    // MARK: Schedule state
    @Published var scheduleEnabled: Bool {
        didSet {
            defaults.set(scheduleEnabled, forKey: Keys.scheduleEnabled)
            if scheduleEnabled, scheduleKind == .sun { location.refreshIfNeeded() }
            evaluateSchedule(force: true)
        }
    }
    @Published var scheduleKind: ScheduleKind {
        didSet {
            defaults.set(scheduleKind.rawValue, forKey: Keys.scheduleKind)
            if scheduleKind == .sun { location.refreshIfNeeded() }
            evaluateSchedule(force: true)
        }
    }
    @Published var dayLevel: BoostLevel {
        didSet { defaults.set(dayLevel.rawValue, forKey: Keys.dayLevel); evaluateSchedule(force: true) }
    }
    @Published var nightLevel: BoostLevel {
        didSet { defaults.set(nightLevel.rawValue, forKey: Keys.nightLevel); evaluateSchedule(force: true) }
    }
    @Published var dayStartMinutes: Int {
        didSet { defaults.set(dayStartMinutes, forKey: Keys.dayStart); evaluateSchedule(force: true) }
    }
    @Published var nightStartMinutes: Int {
        didSet { defaults.set(nightStartMinutes, forKey: Keys.nightStart); evaluateSchedule(force: true) }
    }
    /// True while the current level was set by the schedule (cleared by a manual change).
    @Published private(set) var scheduleControlsLevel = false

    // MARK: App rules state
    @Published private(set) var appRules: [String: BoostLevel]
    @Published private(set) var frontmostBundleID: String?
    /// Last app in front other than us, for "Add <app>".
    @Published private(set) var lastForeignBundleID: String?
    @Published private(set) var launchAtLoginError: String?

    @Published var onlyOnACPower: Bool {
        didSet {
            defaults.set(onlyOnACPower, forKey: Keys.onlyOnAC)
            reevaluate()
        }
    }

    @Published var hotKeyChoice: HotKeyChoice {
        didSet {
            defaults.set(hotKeyChoice.rawValue, forKey: Keys.hotKey)
            hotKey?.apply(hotKeyChoice)
        }
    }

    let power = PowerMonitor()
    let location = LocationProvider()
    let video = VideoPlaybackMonitor()
    let updates = UpdateManager()
    var thermalState: ProcessInfo.ThermalState { power.thermalState }

    private let defaults = UserDefaults.standard
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var screenCancellables: [AnyCancellable] = []
    private var colorTestWindow: NSWindow?
    private var scheduleTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        pauseForVideo = defaults.object(forKey: Keys.pauseForVideo) as? Bool ?? true
        technique = defaults.string(forKey: Keys.technique).flatMap(BoostTechnique.init(rawValue:)) ?? .gammaTable
        if let saved = defaults.string(forKey: Keys.boostLevel).flatMap(BoostLevel.init(rawValue:)) {
            boostLevel = saved
        } else {
            boostLevel = defaults.bool(forKey: Keys.peakMode) ? .peak : .off // migrate 0.1/0.2
        }
        onlyOnACPower = defaults.bool(forKey: Keys.onlyOnAC)
        scheduleEnabled = defaults.bool(forKey: Keys.scheduleEnabled)
        scheduleKind = defaults.string(forKey: Keys.scheduleKind).flatMap(ScheduleKind.init(rawValue:)) ?? .sun
        dayLevel = defaults.string(forKey: Keys.dayLevel).flatMap(BoostLevel.init(rawValue:)) ?? .peak
        nightLevel = defaults.string(forKey: Keys.nightLevel).flatMap(BoostLevel.init(rawValue:)) ?? .off
        dayStartMinutes = defaults.object(forKey: Keys.dayStart) as? Int ?? 7 * 60
        nightStartMinutes = defaults.object(forKey: Keys.nightStart) as? Int ?? 20 * 60
        if let data = defaults.data(forKey: Keys.appRules),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            appRules = raw.compactMapValues(BoostLevel.init(rawValue:))
        } else {
            appRules = [:]
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostBundleID = front
        lastForeignBundleID = front == Bundle.main.bundleIdentifier ? nil : front
        hotKeyChoice = HotKeyChoice(rawValue: defaults.string(forKey: Keys.hotKey) ?? "") ?? .controlOptionCommandB

        power.onChange = { [weak self] in
            self?.reevaluate()
            self?.evaluateSchedule(force: false) // after wake / unlock
        }
        location.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.evaluateSchedule(force: false)
        }
        video.onChange = { [weak self] in self?.reevaluate() }
        if pauseForVideo { video.start() }

        updates.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildScreens() }
            .store(in: &cancellables)

        // App rules follow the frontmost app.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.frontmostAppChanged(app?.bundleIdentifier)
            }
            .store(in: &cancellables)

        // Cmd+Tab / Space switches: keep the overlay on top through the transition.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.screens.forEach { $0.reassertOverlay() } }
                .store(in: &cancellables)
        }

        // Never leave auto-brightness switched off behind us.
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.screens.forEach { $0.tearDown() } }
            .store(in: &cancellables)

        hotKey = GlobalHotKey { [weak self] in self?.toggleFullBrightness() }
        hotKey?.apply(hotKeyChoice)

        reevaluate(applyOverlays: false)
        rebuildScreens()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.evaluateSchedule(force: false) }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
        if scheduleEnabled, scheduleKind == .sun { location.refreshIfNeeded() }
        evaluateSchedule(force: false)
    }

    // MARK: Menu bar icon

    /// 0...1 for the variable SF Symbol in the menu bar.
    var iconLevel: Double {
        guard !screens.isEmpty else { return 1 }
        return screens.map(\.position).max() ?? 1
    }

    /// Filled sun while the boost is actually on, outline otherwise (standard or paused).
    var isBoostActive: Bool { effectiveLevel != .off && pauseReason == nil }

    /// Nits that 100 % means in each mode, for labels (first EDR display's profile).
    func maxNits(for level: BoostLevel) -> Double {
        let profile = screens.first(where: \.supportsEDR)?.profile ?? .xdrDefault
        return level.maxNits(profile)
    }

    // MARK: Boost level

    /// What the displays use right now: the frontmost app's rule, else the selected level.
    var effectiveLevel: BoostLevel {
        if let id = frontmostBundleID, let rule = appRules[id] { return allowed(rule) }
        return boostLevel
    }

    /// Name of the app whose rule is in effect, for the popover caption.
    var activeRuleAppName: String? {
        guard let id = frontmostBundleID, appRules[id] != nil else { return nil }
        return appName(id)
    }

    /// Peak needs the warning to have been accepted once.
    private func allowed(_ level: BoostLevel) -> BoostLevel {
        level == .peak && !defaults.bool(forKey: Keys.peakAcknowledged) ? .sustained : level
    }

    var boostLevelBinding: Binding<BoostLevel> {
        Binding(
            get: { self.boostLevel },
            set: { newValue in
                // Defer so an alert never runs inside a SwiftUI update.
                DispatchQueue.main.async { self.requestBoostLevel(newValue) }
            }
        )
    }

    func requestBoostLevel(_ level: BoostLevel) {
        scheduleControlsLevel = false
        guard level == .peak else {
            setBoostLevel(level)
            return
        }
        if thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "1600-nit mode is unavailable right now")
            alert.informativeText = String(localized: "Your Mac is warm. Peak mode can be turned on again once the thermal state returns to normal.")
            alert.runModal()
            objectWillChange.send()
            return
        }
        if !defaults.bool(forKey: Keys.peakAcknowledged) {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Turn on 1600-nit mode?")
            alert.informativeText = String(localized: "Peak brightness makes the display and your Mac noticeably warmer, drains the battery faster and may accelerate panel ageing. macOS can lower the brightness on its own at any time to protect the display. Highlights may clip if the panel cannot sustain the requested level.")
            alert.addButton(withTitle: String(localized: "Turn On"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                objectWillChange.send()
                return
            }
            defaults.set(true, forKey: Keys.peakAcknowledged)
        }
        setBoostLevel(.peak)
    }

    private func setBoostLevel(_ level: BoostLevel) {
        guard boostLevel != level else { return }
        boostLevel = level
        defaults.set(level.rawValue, forKey: Keys.boostLevel)
        if level != .off { defaults.set(level.rawValue, forKey: Keys.lastBoostLevel) }
        overlayLog.info("boost level \(level.rawValue, privacy: .public)")
        screens.forEach { $0.modeDidChange() }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    // MARK: Hotkey

    /// Full brightness on: last used boost level and macOS brightness 100 % on every display.
    /// Off: standard brightness again (macOS brightness is left where it is).
    func toggleFullBrightness() {
        if boostLevel != .off {
            setBoostLevel(.off)
            return
        }
        var level = defaults.string(forKey: Keys.lastBoostLevel).flatMap(BoostLevel.init(rawValue:)) ?? .sustained
        if level == .peak, !defaults.bool(forKey: Keys.peakAcknowledged) || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            level = .sustained
        }
        if level == .off { level = .sustained }
        setBoostLevel(level)
        screens.forEach { $0.setPosition(1) }
    }

    // MARK: Safety

    func reevaluate(applyOverlays: Bool = true) {
        // No automatic step-down at .fair: it is common under normal load and made the screen
        // dim "for no reason". macOS itself lowers EDR headroom when the panel gets hot.
        let thermal = power.thermalState.rawValue

        let reason: PauseReason?
        if thermal >= ProcessInfo.ThermalState.serious.rawValue {
            reason = .thermal
        } else if power.isSuspended {
            reason = .screensAsleep
        } else if !power.isOnACPower, let battery = power.batteryPercent, battery < 20 {
            reason = .lowBattery
        } else if onlyOnACPower, !power.isOnACPower {
            reason = .onBattery
        } else if pauseForVideo, video.isPlayingVideo {
            reason = .videoPlaying
        } else {
            reason = nil
        }
        if reason != pauseReason {
            pauseReason = reason
            if let reason {
                lastPause = PauseEvent(reason: reason, date: Date())
                overlayLog.info("paused: \(reason.title, privacy: .public)")
            }
        }
        objectWillChange.send()

        if applyOverlays { screens.forEach { $0.applyOverlay(animated: true) } }
    }

    // MARK: Schedule

    /// Today's sunrise and sunset at the cached location.
    var todaysSunTimes: (sunrise: Date, sunset: Date)? {
        guard let c = location.coordinate else { return nil }
        return SolarCalculator.sunTimes(on: Date(), latitude: c.latitude, longitude: c.longitude)
    }

    func currentPeriod(at date: Date = Date()) -> DayPeriod? {
        switch scheduleKind {
        case .sun:
            guard let c = location.coordinate else { return nil }
            guard let times = SolarCalculator.sunTimes(on: date, latitude: c.latitude, longitude: c.longitude) else {
                // Polar day/night: decide by whether the sun is up at local noon.
                let summer = (c.latitude >= 0) == (4...9).contains(Calendar.current.component(.month, from: date))
                return summer ? .day : .night
            }
            return date >= times.sunrise && date < times.sunset ? .day : .night
        case .custom:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if dayStartMinutes == nightStartMinutes { return .day }
            if dayStartMinutes < nightStartMinutes {
                return minute >= dayStartMinutes && minute < nightStartMinutes ? .day : .night
            }
            return minute >= dayStartMinutes || minute < nightStartMinutes ? .day : .night
        }
    }

    /// Like Night Shift: at each boundary the period's level is applied; a manual change
    /// stays until the next boundary. `force` applies the current period right away.
    func evaluateSchedule(force: Bool) {
        guard scheduleEnabled, let period = currentPeriod() else { return }
        let last = defaults.string(forKey: Keys.lastPeriod)
        guard force || last != period.rawValue else { return }
        defaults.set(period.rawValue, forKey: Keys.lastPeriod)
        let level = allowed(period == .day ? dayLevel : nightLevel)
        overlayLog.info("schedule: \(period.rawValue, privacy: .public) -> \(level.rawValue, privacy: .public)")
        setBoostLevel(level)
        scheduleControlsLevel = true
    }

    struct ScheduleSwitch {
        let date: Date
        let period: DayPeriod
        let level: BoostLevel
    }

    /// The next time the schedule changes the level, for the popover.
    var nextScheduleSwitch: ScheduleSwitch? {
        guard scheduleEnabled else { return nil }
        let now = Date()
        var candidates: [(Date, DayPeriod)] = []
        for offset in 0...2 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now) else { continue }
            switch scheduleKind {
            case .sun:
                guard let c = location.coordinate,
                      let times = SolarCalculator.sunTimes(on: day, latitude: c.latitude, longitude: c.longitude) else { continue }
                candidates.append((times.sunrise, .day))
                candidates.append((times.sunset, .night))
            case .custom:
                for (minutes, period) in [(dayStartMinutes, DayPeriod.day), (nightStartMinutes, .night)] {
                    if let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) {
                        candidates.append((date, period))
                    }
                }
            }
        }
        guard let next = candidates.filter({ $0.0 > now }).min(by: { $0.0 < $1.0 }) else { return nil }
        return ScheduleSwitch(date: next.0, period: next.1, level: allowed(next.1 == .day ? dayLevel : nightLevel))
    }

    func levelTitle(_ level: BoostLevel) -> String {
        level == .off ? String(localized: "Standard") : "\(Int(maxNits(for: level).rounded())) nit"
    }

    /// Roughly how bright full macOS brightness is right now on the first EDR display.
    var currentPeakNits: Double? {
        guard let screen = screens.first(where: \.supportsEDR), isBoostActive else { return nil }
        return screen.profile.sdrNits * screen.appliedGain
    }

    func timeBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = self[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                self[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    // MARK: App rules

    private func frontmostAppChanged(_ bundleID: String?) {
        let before = effectiveLevel
        if bundleID != Bundle.main.bundleIdentifier {
            // Our own Settings window doesn't count as "the app in front".
            frontmostBundleID = bundleID
            lastForeignBundleID = bundleID
        }
        if effectiveLevel != before {
            overlayLog.info("app rule: \(bundleID ?? "-", privacy: .public) -> \(self.effectiveLevel.rawValue, privacy: .public)")
            screens.forEach { $0.modeDidChange() }
        }
    }

    var sortedRuleIDs: [String] {
        appRules.keys.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func appIcon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func ruleBinding(_ bundleID: String) -> Binding<BoostLevel> {
        Binding(
            get: { self.appRules[bundleID] ?? .off },
            set: { self.setRule(bundleID, level: $0) }
        )
    }

    func setRule(_ bundleID: String, level: BoostLevel?) {
        let before = effectiveLevel
        appRules[bundleID] = level
        if let data = try? JSONEncoder().encode(appRules.mapValues(\.rawValue)) {
            defaults.set(data, forKey: Keys.appRules)
        }
        if effectiveLevel != before { screens.forEach { $0.modeDidChange() } }
    }

    func addRuleFromPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, appRules[id] == nil { setRule(id, level: .off) }
        }
    }

    // MARK: Screens

    private func rebuildScreens() {
        var result: [ScreenController] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if let existing = screens.first(where: { $0.displayID == id }) {
                existing.update(screen: screen)
                result.append(existing)
            } else {
                let controller = ScreenController(screen: screen, displayID: id, model: self)
                controller.applyOverlay(animated: true)
                result.append(controller)
            }
        }
        for old in screens where !result.contains(where: { $0 === old }) {
            old.tearDown()
        }
        // didChangeScreenParameters also fires on every headroom change and in fullscreen
        // apps; when the set of displays is the same, nothing else needs to change.
        guard result.map(\.displayID) != screens.map(\.displayID) else { return }
        screens = result
        screenCancellables = result.map { screen in
            screen.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    // MARK: Color test

    func openColorTest() {
        if colorTestWindow == nil {
            let test = ColorTestModel(app: self)
            let hosting = NSHostingController(rootView: ColorTestView(test: test).environmentObject(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Color Test")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            colorTestWindow = window
        }
        NSApp.activate()
        colorTestWindow?.makeKeyAndOrderFront(nil)
    }
}
