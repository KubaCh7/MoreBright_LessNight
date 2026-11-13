import AppKit
import Foundation
import IOKit.ps

/// Thermal state, power source, battery level and display sleep. Main-thread only.
final class PowerMonitor {
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var isOnACPower = true
    private(set) var batteryPercent: Int?
    private(set) var screensAsleep = false

    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        readPowerSource()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.readPowerSource()
            monitor.onChange?()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
            self?.onChange?()
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        let sleepEvents: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.didWakeNotification, false),
        ]
        for (name, asleep) in sleepEvents {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screensAsleep = asleep
                self?.onChange?()
            }))
        }
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func readPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            isOnACPower = (type as String) == "AC Power"
        }
        batteryPercent = nil
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray? else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int, maximum > 0 else { continue }
            batteryPercent = current * 100 / maximum
        }
    }
}

extension ProcessInfo.ThermalState {
    var localizedName: String {
        switch self {
        case .nominal: return String(localized: "Nominal")
        case .fair: return String(localized: "Fair")
        case .serious: return String(localized: "Serious")
        case .critical: return String(localized: "Critical")
        @unknown default: return String(localized: "Unknown")
        }
    }
}
