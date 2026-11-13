import CoreGraphics
import Foundation

/// Thin bridge to the private DisplayServices framework, loaded at runtime with dlopen.
///
/// Rules this file enforces (see README, "Zero interference"):
/// - Writes happen only through `setBrightness`, which is called only from a user slider action.
/// - Reads are passive: a change callback plus a ≤ 1 Hz safety read. Nothing here ever writes back.
enum DisplayServices {
    fileprivate typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    fileprivate typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    fileprivate typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    fileprivate typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32
    fileprivate typealias UnregisterFn = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let getFn = symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    private static let setFn = symbol("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    private static let canChangeFn = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
    fileprivate static let registerFn = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)
    fileprivate static let unregisterFn = symbol("DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterFn.self)

    static func brightness(_ display: CGDirectDisplayID) -> Double? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    static func canChangeBrightness(_ display: CGDirectDisplayID) -> Bool {
        guard setFn != nil, brightness(display) != nil else { return false }
        return canChangeFn?(display) ?? true
    }

    /// Only call this in response to the user moving our slider (or the user's own hotkey).
    static func setBrightness(_ display: CGDirectDisplayID, _ value: Double) {
        _ = setFn?(display, Float(min(max(value, 0), 1)))
    }
}

// MARK: - Passive observation

/// Main-thread only.
private var brightnessHandlers: [CGDirectDisplayID: (Double) -> Void] = [:]

private let brightnessChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    let display = CGDirectDisplayID(truncatingIfNeeded: UInt(bitPattern: observer))
    DispatchQueue.main.async {
        guard let handler = brightnessHandlers[display],
              let value = DisplayServices.brightness(display) else { return }
        handler(value)
    }
}

/// Observes brightness changes made by anyone (F1/F2, Control Center, ambient sensor, Vorsaint...).
/// Never writes. Duplicate values are filtered so handlers only see real changes.
final class BrightnessObservation {
    private let display: CGDirectDisplayID
    private var registered = false
    private var safetyTimer: Timer?
    private var lastValue: Double?

    init(display: CGDirectDisplayID, handler: @escaping (Double) -> Void) {
        self.display = display
        lastValue = DisplayServices.brightness(display)

        let deduplicating: (Double) -> Void = { [weak self] value in
            guard let self else { return }
            if let last = self.lastValue, abs(last - value) < 0.0005 { return }
            self.lastValue = value
            handler(value)
        }
        brightnessHandlers[display] = deduplicating

        if let register = DisplayServices.registerFn {
            let observer = UnsafeMutableRawPointer(bitPattern: UInt(display))
            registered = register(display, observer, brightnessChangedCallback) == 0
        }

        // Safety net: the private callback is not guaranteed to fire on every macOS build.
        // 1 Hz passive read (spec allows up to 2 Hz). Read-only, never writes.
        let interval: TimeInterval = registered ? 1.0 : 0.5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let value = DisplayServices.brightness(self.display) else { return }
            brightnessHandlers[self.display]?(value)
        }
        timer.tolerance = interval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    /// Updates the dedup baseline after our own write so the echo is not reported as external.
    func noteOwnWrite(_ value: Double) {
        lastValue = value
    }

    func invalidate() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        if registered, let unregister = DisplayServices.unregisterFn {
            _ = unregister(display, UnsafeMutableRawPointer(bitPattern: UInt(display)))
            registered = false
        }
        brightnessHandlers[display] = nil
    }

    deinit { invalidate() }
}
