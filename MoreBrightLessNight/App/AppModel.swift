import AppKit
import Combine
import ServiceManagement
import SwiftUI

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
    @Published private(set) var peakAutoDisabled = false
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
    let video = VideoPlaybackMonitor()
    let updates = UpdateManager()
    var thermalState: ProcessInfo.ThermalState { power.thermalState }

    private let defaults = UserDefaults.standard
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var screenCancellables: [AnyCancellable] = []
    private var colorTestWindow: NSWindow?

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
        hotKeyChoice = HotKeyChoice(rawValue: defaults.string(forKey: Keys.hotKey) ?? "") ?? .controlOptionCommandB

        power.onChange = { [weak self] in self?.reevaluate() }
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

        // Cmd+Tab / Space switches: keep the overlay on top through the transition.
        let workspace = NSWorkspace.shared.notificationCenter
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
    }

    // MARK: Menu bar icon

    /// 0...1 for the variable SF Symbol in the menu bar.
    var iconLevel: Double {
        guard !screens.isEmpty else { return 1 }
        return screens.map(\.position).max() ?? 1
    }

    /// Nits that 100 % means in each mode, for labels (first EDR display's profile).
    func maxNits(for level: BoostLevel) -> Double {
        let profile = screens.first(where: \.supportsEDR)?.profile ?? .xdrDefault
        return level.maxNits(profile)
    }

    // MARK: Boost level

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
        guard level == .peak else {
            setBoostLevel(level)
            return
        }
        if thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue {
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
        peakAutoDisabled = false
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
        if level == .peak, !defaults.bool(forKey: Keys.peakAcknowledged) || thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue {
            level = .sustained
        }
        if level == .off { level = .sustained }
        setBoostLevel(level)
        screens.forEach { $0.setPosition(1) }
    }

    // MARK: Safety

    func reevaluate(applyOverlays: Bool = true) {
        let thermal = power.thermalState.rawValue
        // Peak steps down to sustained (persistently) once the Mac leaves the nominal state.
        if boostLevel == .peak, thermal >= ProcessInfo.ThermalState.fair.rawValue {
            peakAutoDisabled = true
            setBoostLevel(.sustained)
        }

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
        if reason != pauseReason { pauseReason = reason }
        objectWillChange.send()

        if applyOverlays { screens.forEach { $0.applyOverlay(animated: true) } }
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
