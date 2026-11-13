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
        static let pauseAutoBrightness = "pauseAutoBrightness"
    }

    @Published private(set) var screens: [ScreenController] = []
    @Published private(set) var peakModeEnabled: Bool
    @Published private(set) var pauseReason: PauseReason?
    @Published private(set) var peakAutoDisabled = false
    @Published private(set) var launchAtLoginError: String?

    @Published var onlyOnACPower: Bool {
        didSet {
            defaults.set(onlyOnACPower, forKey: Keys.onlyOnAC)
            reevaluate()
        }
    }

    /// While boosting, macOS auto-brightness is paused (it would pull brightness down under
    /// the boost) and restored afterwards, like BetterDisplay and Lunar do.
    @Published var pauseAutoBrightness: Bool {
        didSet {
            defaults.set(pauseAutoBrightness, forKey: Keys.pauseAutoBrightness)
            if !pauseAutoBrightness { screens.forEach { $0.restoreAutoBrightness() } }
            screens.forEach { $0.applyOverlay(animated: true) }
        }
    }

    @Published var hotKeyChoice: HotKeyChoice {
        didSet {
            defaults.set(hotKeyChoice.rawValue, forKey: Keys.hotKey)
            hotKey?.apply(hotKeyChoice)
        }
    }

    let power = PowerMonitor()
    let updates = UpdateManager()
    var thermalState: ProcessInfo.ThermalState { power.thermalState }

    private let defaults = UserDefaults.standard
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var screenCancellables: [AnyCancellable] = []
    private var fullBrightnessSnapshot: [String: Double]?
    private var colorTestWindow: NSWindow?

    init() {
        let defaults = UserDefaults.standard
        peakModeEnabled = defaults.bool(forKey: Keys.peakMode)
        onlyOnACPower = defaults.bool(forKey: Keys.onlyOnAC)
        pauseAutoBrightness = defaults.object(forKey: Keys.pauseAutoBrightness) as? Bool ?? true
        hotKeyChoice = HotKeyChoice(rawValue: defaults.string(forKey: Keys.hotKey) ?? "") ?? .controlOptionCommandB

        power.onChange = { [weak self] in self?.reevaluate() }

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
        let supported = screens.filter(\.supportsEDR)
        guard !supported.isEmpty else { return 1 }
        return supported.map(\.position).max() ?? 1
    }

    // MARK: Peak mode

    var peakModeBinding: Binding<Bool> {
        Binding(
            get: { self.peakModeEnabled },
            set: { newValue in
                // Defer so an alert never runs inside a SwiftUI update.
                DispatchQueue.main.async { self.requestPeakMode(newValue) }
            }
        )
    }

    func requestPeakMode(_ enable: Bool) {
        guard enable else {
            setPeakMode(false)
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
        setPeakMode(true)
    }

    private func setPeakMode(_ enabled: Bool) {
        guard peakModeEnabled != enabled else { return }
        peakModeEnabled = enabled
        defaults.set(enabled, forKey: Keys.peakMode)
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

    /// Full brightness on: every EDR display to 100 %. Off: back to the previous positions.
    func toggleFullBrightness() {
        let supported = screens.filter(\.supportsEDR)
        guard !supported.isEmpty else { return }
        let allFull = supported.allSatisfy { $0.position >= 0.999 }
        if allFull, let snapshot = fullBrightnessSnapshot {
            for screen in supported { screen.setPosition(snapshot[screen.key] ?? screen.knee) }
            fullBrightnessSnapshot = nil
        } else {
            fullBrightnessSnapshot = Dictionary(supported.map { ($0.key, $0.position) }, uniquingKeysWith: { first, _ in first })
            supported.forEach { $0.setPosition(1) }
        }
    }

    // MARK: Safety

    func reevaluate(applyOverlays: Bool = true) {
        let thermal = power.thermalState.rawValue
        // Peak mode turns itself off (persistently) once the Mac leaves the nominal state.
        if peakModeEnabled, thermal >= ProcessInfo.ThermalState.fair.rawValue {
            peakAutoDisabled = true
            setPeakMode(false)
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
