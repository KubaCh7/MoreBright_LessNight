import AppKit
import ColorSync

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Stable per-panel key for persisting settings (survives reboots and reconnects,
/// unlike CGDirectDisplayID which can change).
/// Many monitors report serial 0, so two identical ones would collide; then the
/// ColorSync display UUID (stable per panel/port) is appended.
func persistentKey(for display: CGDirectDisplayID) -> String {
    let base = "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))"
    guard CGDisplaySerialNumber(display) == 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let string = CFUUIDCreateString(nil, uuid) as String? else { return base }
    return base + "-" + string
}

/// Brightness model of a panel, in nits. Used only to place the knee on the slider
/// and to cap the boost; the actual light output is decided by macOS and the panel.
struct NitsProfile: Codable, Equatable {
    var sdrNits: Double
    var sustainedNits: Double
    var peakNits: Double

    /// MacBook Pro Liquid Retina XDR / Pro Display XDR.
    static let xdrDefault = NitsProfile(sdrNits: 500, sustainedNits: 1000, peakNits: 1600)

    var sanitized: NitsProfile {
        let sdr = min(max(sdrNits, 50), 3000)
        let sustained = min(max(sustainedNits, sdr), 10000)
        let peak = min(max(peakNits, sustained), 10000)
        return NitsProfile(sdrNits: sdr, sustainedNits: sustained, peakNits: peak)
    }
}
