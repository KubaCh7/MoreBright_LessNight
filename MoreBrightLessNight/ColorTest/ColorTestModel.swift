import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

struct ReferencePatch: Identifiable {
    let id: Int
    let nameKey: String
    let r: Double, g: Double, b: Double

    static let all: [ReferencePatch] = [
        ReferencePatch(id: 0, nameKey: "Red", r: 0.85, g: 0.15, b: 0.15),
        ReferencePatch(id: 1, nameKey: "Green", r: 0.20, g: 0.70, b: 0.25),
        ReferencePatch(id: 2, nameKey: "Blue", r: 0.15, g: 0.25, b: 0.85),
        ReferencePatch(id: 3, nameKey: "Cyan", r: 0.10, g: 0.70, b: 0.80),
        ReferencePatch(id: 4, nameKey: "Magenta", r: 0.80, g: 0.20, b: 0.70),
        ReferencePatch(id: 5, nameKey: "Yellow", r: 0.90, g: 0.80, b: 0.15),
        ReferencePatch(id: 6, nameKey: "Dark gray", r: 0.20, g: 0.20, b: 0.20),
        ReferencePatch(id: 7, nameKey: "Mid gray", r: 0.50, g: 0.50, b: 0.50),
        ReferencePatch(id: 8, nameKey: "Light gray", r: 0.80, g: 0.80, b: 0.80),
        ReferencePatch(id: 9, nameKey: "White", r: 1.00, g: 1.00, b: 1.00),
        ReferencePatch(id: 10, nameKey: "Light skin", r: 0.761, g: 0.588, b: 0.510),
        ReferencePatch(id: 11, nameKey: "Dark skin", r: 0.451, g: 0.318, b: 0.267),
    ]

    static let columns = 6
    static var rows: Int { (all.count + columns - 1) / columns }
}

struct PatchResult: Identifiable {
    let id: Int
    let nameKey: String
    /// CIEDE2000 between before and after, after normalising luminance: pure hue/chroma shift.
    let deltaE: Double
    let measuredGain: Double
    let clipped: Bool
}

struct ColorTestResult {
    let expectedGain: Double
    let patches: [PatchResult]
    let captureLacksEDR: Bool

    var maxDeltaE: Double { patches.map(\.deltaE).max() ?? 0 }
    var meanDeltaE: Double { patches.isEmpty ? 0 : patches.map(\.deltaE).reduce(0, +) / Double(patches.count) }
    var anyClipped: Bool { patches.contains(where: \.clipped) }
}

enum ColorTestError: LocalizedError {
    case noWindow, notBoosted, noDisplay, noImage

    var errorDescription: String? {
        switch self {
        case .noWindow: return String(localized: "Open the test window on an EDR display first.")
        case .notBoosted: return String(localized: "Move the slider above the system maximum first, so there is a boost to measure.")
        case .noDisplay: return String(localized: "ScreenCaptureKit did not return this display. Check Screen Recording permission in System Settings.")
        case .noImage: return String(localized: "The capture returned no image.")
        }
    }
}

final class ColorTestModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var result: ColorTestResult?
    @Published private(set) var errorMessage: String?

    weak var app: AppModel?
    weak var patchesView: PatchesNSView?

    init(app: AppModel) {
        self.app = app
    }

    @MainActor
    func measure() async {
        guard !isRunning else { return }
        errorMessage = nil
        isRunning = true
        defer { isRunning = false }

        do {
            guard let view = patchesView, let window = view.window, let screen = window.screen,
                  let displayID = screen.displayID,
                  let controller = app?.screens.first(where: { $0.displayID == displayID }) else {
                throw ColorTestError.noWindow
            }
            let expected = controller.effectiveGain
            guard expected > 1.01 else { throw ColorTestError.notBoosted }

            let inScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
            let frame = screen.frame
            let rect = CGRect(x: inScreen.minX - frame.minX, y: frame.maxY - inScreen.maxY,
                              width: inScreen.width, height: inScreen.height)
            let scale = screen.backingScaleFactor

            controller.setOverlayCaptureVisible(true)
            defer {
                controller.overrideGain = nil
                controller.setOverlayCaptureVisible(false)
            }

            controller.overrideGain = 1
            try await Task.sleep(for: .milliseconds(500))
            let before = try await Self.capture(displayID: displayID, rect: rect, scale: scale)

            controller.overrideGain = nil
            try await Task.sleep(for: .milliseconds(800))
            let after = try await Self.capture(displayID: displayID, rect: rect, scale: scale)

            result = Self.analyze(before: before, after: after, expected: expected)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Capture

    private struct Capture {
        let width: Int
        let height: Int
        let rgba: [Float]
    }

    private static func capture(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat) async throws -> Capture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ColorTestError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.pixelFormat = kCVPixelFormatType_64RGBAHalf
        config.colorSpaceName = CGColorSpace.extendedLinearSRGB
        config.showsCursor = false
        if #available(macOS 15.0, *) {
            config.captureDynamicRange = .hdrLocalDisplay
        }

        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw ColorTestError.noImage }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ColorTestError.noImage }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for i in 0..<(width * 4) {
                rgba[y * width * 4 + i] = ColorMath.halfToFloat(row[i])
            }
        }
        return Capture(width: width, height: height, rgba: rgba)
    }

    // MARK: Analysis

    private static func mean(of capture: Capture, patch index: Int) -> LinearRGB {
        let column = index % ReferencePatch.columns
        let row = index / ReferencePatch.columns
        let cellW = Double(capture.width) / Double(ReferencePatch.columns)
        let cellH = Double(capture.height) / Double(ReferencePatch.rows)
        // Central 40 % of the cell, away from the gaps and edges.
        let x0 = Int(cellW * (Double(column) + 0.3)), x1 = Int(cellW * (Double(column) + 0.7))
        let y0 = Int(cellH * (Double(row) + 0.3)), y1 = Int(cellH * (Double(row) + 0.7))
        var sum = (0.0, 0.0, 0.0)
        var count = 0.0
        for y in max(0, y0)..<min(capture.height, y1) {
            for x in max(0, x0)..<min(capture.width, x1) {
                let i = (y * capture.width + x) * 4
                sum.0 += Double(capture.rgba[i])
                sum.1 += Double(capture.rgba[i + 1])
                sum.2 += Double(capture.rgba[i + 2])
                count += 1
            }
        }
        guard count > 0 else { return LinearRGB(r: 0, g: 0, b: 0) }
        return LinearRGB(r: sum.0 / count, g: sum.1 / count, b: sum.2 / count)
    }

    private static func analyze(before: Capture, after: Capture, expected: Double) -> ColorTestResult {
        var patches: [PatchResult] = []
        for patch in ReferencePatch.all {
            let b = mean(of: before, patch: patch.id)
            let a = mean(of: after, patch: patch.id)
            let yb = max(b.luminance, 1e-6), ya = max(a.luminance, 1e-6)
            let gain = ya / yb
            // Compare at equal luminance: what remains is the hue/chroma shift.
            let deltaE = ColorMath.deltaE2000(b.lab, a.scaled(by: yb / ya).lab)
            patches.append(PatchResult(id: patch.id, nameKey: patch.nameKey, deltaE: deltaE,
                                       measuredGain: gain, clipped: gain < expected * 0.92))
        }
        let gains = patches.map(\.measuredGain).sorted()
        let median = gains.isEmpty ? 1 : gains[gains.count / 2]
        return ColorTestResult(expectedGain: expected, patches: patches,
                               captureLacksEDR: expected > 1.2 && median < 1.05)
    }
}
