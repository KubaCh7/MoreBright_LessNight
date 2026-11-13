import AppKit
import SwiftUI

/// Draws the reference patches in plain SDR sRGB with a deterministic grid,
/// so the capture can be sampled at known positions.
final class PatchesNSView: NSView {
    static let cellSize = NSSize(width: 76, height: 60)
    static let gap: CGFloat = 4

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.cellSize.width * CGFloat(ReferencePatch.columns),
               height: Self.cellSize.height * CGFloat(ReferencePatch.rows))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let cellW = bounds.width / CGFloat(ReferencePatch.columns)
        let cellH = bounds.height / CGFloat(ReferencePatch.rows)
        for patch in ReferencePatch.all {
            let column = patch.id % ReferencePatch.columns
            let row = patch.id / ReferencePatch.columns
            let rect = NSRect(x: CGFloat(column) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
                .insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
            NSColor(srgbRed: patch.r, green: patch.g, blue: patch.b, alpha: 1).setFill()
            rect.fill()
        }
    }
}

private struct PatchesRepresentable: NSViewRepresentable {
    let test: ColorTestModel

    func makeNSView(context: Context) -> PatchesNSView {
        let view = PatchesNSView()
        test.patchesView = view
        view.setAccessibilityLabel(String(localized: "Reference color patches"))
        return view
    }

    func updateNSView(_ nsView: PatchesNSView, context: Context) {
        test.patchesView = nsView
    }
}

struct ColorTestView: View {
    @ObservedObject var test: ColorTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reference Patches")
                .font(.headline)
            Text("Choose 1000 nit or 1600 nit, keep this window on that display and click Measure. The boost is turned off briefly for the “before” capture.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PatchesRepresentable(test: test)
                .frame(width: PatchesNSView.cellSize.width * CGFloat(ReferencePatch.columns),
                       height: PatchesNSView.cellSize.height * CGFloat(ReferencePatch.rows))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 8) {
                Button("Measure") { Task { await test.measure() } }
                    .disabled(test.isRunning)
                    .keyboardShortcut(.defaultAction)
                if test.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            if let error = test.errorMessage {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let result = test.result {
                ResultView(result: result)
            }
        }
        .padding(16)
        .frame(width: PatchesNSView.cellSize.width * CGFloat(ReferencePatch.columns) + 32)
    }
}

private struct ResultView: View {
    let result: ColorTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.captureLacksEDR {
                Label {
                    Text("The capture did not include the boost (ScreenCaptureKit returned SDR values). The ΔE result below is not meaningful on this macOS version.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                .font(.callout)
            }
            if result.anyClipped {
                ClippedWarning()
            }

            HStack(spacing: 16) {
                LabeledContent("Expected gain") { Text(verbatim: String(format: "%.2f×", result.expectedGain)) }
                LabeledContent("Mean ΔE00") { Text(verbatim: String(format: "%.2f", result.meanDeltaE)) }
                LabeledContent("Max ΔE00") { Text(verbatim: String(format: "%.2f", result.maxDeltaE)) }
            }
            .monospacedDigit()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Patch").font(.caption.weight(.semibold))
                    Text("ΔE00").font(.caption.weight(.semibold))
                    Text("Gain").font(.caption.weight(.semibold))
                    Text(verbatim: "")
                }
                ForEach(result.patches) { patch in
                    GridRow {
                        Text(LocalizedStringKey(patch.nameKey))
                        Text(verbatim: String(format: "%.2f", patch.deltaE)).monospacedDigit()
                        Text(verbatim: String(format: "%.2f×", patch.measuredGain)).monospacedDigit()
                        if patch.clipped {
                            Text("clipped").foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: "")
                        }
                    }
                    .font(.caption)
                }
            }

            Text("ΔE00 is computed after normalising luminance, so it measures only hue and chroma shift. Below 1 is invisible, below 2 is hard to notice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
