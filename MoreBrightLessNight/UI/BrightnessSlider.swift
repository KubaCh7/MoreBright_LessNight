import SwiftUI

/// Thick, rounded slider modelled on the Control Center brightness slider.
/// For VoiceOver and keyboard it is represented by a standard `Slider`.
struct BrightnessSlider: View {
    @Binding var value: Double
    /// Optional tick showing where the system maximum ends and EDR begins.
    var knee: Double?
    var accessibilityLabel: Text

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    private let height: CGFloat = 24
    private let step = 1.0 / 32.0

    var body: some View {
        HStack(spacing: 10) {
            track
            Text(value, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1, step: step) { accessibilityLabel }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = height + (width - height) * value

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillWidth)
                if let knee, knee > 0, knee < 1 {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 2, height: height * 0.4)
                        .offset(x: height / 2 + (width - height) * knee - 1)
                        .opacity(value < knee ? 1 : 0.5)
                }
                Image(systemName: value < 0.5 ? "sun.min.fill" : "sun.max.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: height, height: height)
            }
            .overlay {
                if contrast == .increased || isFocused {
                    Capsule().strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(0.6),
                                           lineWidth: isFocused ? 2 : 1)
                }
            }
            .animation(isDragging || reduceMotion ? nil : .snappy, value: value)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let raw = (gesture.location.x - height / 2) / max(1, width - height)
                        value = min(max(raw, 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: height)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-step) }
        .onKeyPress(.downArrow) { nudge(-step) }
        .onKeyPress(.rightArrow) { nudge(step) }
        .onKeyPress(.upArrow) { nudge(step) }
    }

    private func nudge(_ delta: Double) -> KeyPress.Result {
        value = min(max(value + delta, 0), 1)
        return .handled
    }
}
