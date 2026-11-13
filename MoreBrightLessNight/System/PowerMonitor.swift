import AppKit
import Foundation
import IOKit.ps
import os

/// Thermal state, power source, battery level, and "suspended" (display asleep, system
/// sleeping, screen locked, screensaver, session switched away, displays reconfiguring).
/// Like BrightIntosh, the boost resumes only 5 s after the last suspend reason clears, so
/// EDR is not requested while macOS is still rebuilding the display pipeline. Main-thread only.
final class PowerMonitor {
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var isOnACPower = true
    private(set) var batteryPercent: Int?
    private(set) var isSuspended = false

    static let resumeDelay: TimeInterval = 5
    private var suspendReasons: Set<String> = []
    private var resumeWorkItem: DispatchWorkItem?

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
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
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
        let workspaceEvents: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, "screensAsleep", true),
            (NSWorkspace.screensDidWakeNotification, "screensAsleep", false),
            (NSWorkspace.willSleepNotification, "systemAsleep", true),
            (NSWorkspace.didWakeNotification, "systemAsleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "sessionInactive", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "sessionInactive", false),
        ]
        for (name, reason, active) in workspaceEvents {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setSuspendReason(reason, active: active)
            }))
        }

        let distributed = DistributedNotificationCenter.default()
        let distributedEvents: [(String, String, Bool)] = [
            ("com.apple.screensaver.didstart", "screensaver", true),
            ("com.apple.screensaver.didstop", "screensaver", false),
            ("com.apple.screenIsLocked", "locked", true),
            ("com.apple.screenIsUnlocked", "locked", false),
        ]
        for (name, reason, active) in distributedEvents {
            observers.append((distributed, distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                self?.setSuspendReason(reason, active: active)
            }))
        }

        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            setSuspendReason("screensAsleep", active: true)
        }
    }

    /// Only topology changes (display added/removed/enabled/mirrored) pause the boost.
    /// Mode and headroom changes must not, or engaging EDR could pause itself.
    fileprivate func displayReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        let topology: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag,
                                                     .disabledFlag, .mirrorFlag, .unMirrorFlag]
        guard !flags.contains(.beginConfigurationFlag), !flags.intersection(topology).isEmpty else { return }
        setSuspendReason("reconfiguring", active: true)
        setSuspendReason("reconfiguring", active: false) // resumes after resumeDelay
    }

    private func setSuspendReason(_ reason: String, active: Bool) {
        if active {
            suspendReasons.insert(reason)
        } else {
            suspendReasons.remove(reason)
        }
        if !suspendReasons.isEmpty {
            resumeWorkItem?.cancel()
            resumeWorkItem = nil
            if !isSuspended {
                isSuspended = true
                overlayLog.info("suspended: \(self.suspendReasons.sorted().joined(separator: ","), privacy: .public)")
                onChange?()
            }
        } else if isSuspended, resumeWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resumeWorkItem = nil
                guard self.suspendReasons.isEmpty else { return }
                self.isSuspended = false
                overlayLog.info("resumed")
                self.onChange?()
            }
            resumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDelay, execute: work)
        }
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
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

/// Delivered on the main run loop (the thread that registered it).
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else { return }
    Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().displayReconfiguration(flags)
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
