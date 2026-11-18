import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader()

            BoostLevelPicker()

            if model.screens.isEmpty {
                Text("No displays found")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.screens) { screen in
                ScreenBrightnessRow(screen: screen)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.pauseForVideo) {
                    Label {
                        Text("Pause during video")
                    } icon: {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                    }
                }
                .toggleStyle(.switch)

                NextScheduleRow()
            }

            UpdateBanner(updates: model.updates)

            Divider()

            HStack(spacing: 14) {
                Button { model.openColorTest() } label: {
                    Label("Color Test…", systemImage: "eyedropper.halffull")
                }
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 330)
    }
}

/// Big status at the top: what the screen is doing right now, at a glance.
struct PopoverHeader: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        if model.pauseReason != nil { return "pause.circle.fill" }
        return model.isBoostActive ? "sun.max.fill" : "sun.min.fill"
    }

    private var tint: Color {
        if model.pauseReason != nil { return .secondary }
        return model.isBoostActive ? .yellow : .orange
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "MoreBrightLessNight")
                    .font(.headline)
                Group {
                    if let reason = model.pauseReason {
                        Text(verbatim: reason.title)
                    } else if model.isBoostActive {
                        Text("Boost on")
                    } else {
                        Text("Standard brightness")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let nits = model.currentPeakNits {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(verbatim: "\(Int(nits.rounded()))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(verbatim: "nit max")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: symbol)
    }
}

/// "Sunset 15:41 → Standard" when a schedule is on.
struct NextScheduleRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let next = model.nextScheduleSwitch {
            HStack(spacing: 6) {
                Image(systemName: icon(for: next.period))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 18)
                Group {
                    if model.scheduleKind == .sun {
                        if next.period == .day { Text("Sunrise") } else { Text("Sunset") }
                    } else {
                        if next.period == .day { Text("Day") } else { Text("Night") }
                    }
                }
                Text(next.date, style: .time).monospacedDigit()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: model.levelTitle(next.level))
                    .fontWeight(.medium)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
    }

    private func icon(for period: DayPeriod) -> String {
        if model.scheduleKind == .sun { return period == .day ? "sunrise.fill" : "sunset.fill" }
        return period == .day ? "sun.max.fill" : "moon.stars.fill"
    }
}

struct ScreenBrightnessRow: View {
    @ObservedObject var screen: ScreenController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: screen.name)
                } icon: {
                    Image(systemName: "laptopcomputer")
                }
                .font(.subheadline.weight(.medium))
                Spacer()
                StatusLabel(status: screen.status)
            }

            if screen.supportsEDR {
                BrightnessSlider(
                    value: Binding(get: { screen.position }, set: { screen.setPosition($0) }),
                    accessibilityLabel: Text("Brightness for \(screen.name)")
                )
                if screen.boostLevel != .off {
                    Text(verbatim: "100 % = \(Int(screen.fullScaleNits.rounded())) nit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let nits = screen.limitedToNits {
                    HeadroomLimitNote(nits: nits)
                }
                if screen.highlightsClipped {
                    ClippedWarning()
                }
            } else {
                Text("This display has no EDR headroom, so brightness can't go above the system maximum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct StatusLabel: View {
    let status: ScreenStatus

    var body: some View {
        Label {
            Text(verbatim: status.title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: status.symbol).foregroundStyle(color)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private var color: Color {
        switch status {
        case .fullPower: return .green
        case .thermallyLimited: return .orange
        case .unsupported: return .secondary
        case .paused: return .secondary
        }
    }
}

struct ClippedWarning: View {
    var body: some View {
        Label {
            Text("Highlights clipped right now")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// macOS grants less EDR headroom than the mode asks for (heat, panel limit). The boost is
/// capped to it, so nothing clips; the display just tops out lower.
struct HeadroomLimitNote: View {
    let nits: Double

    var body: some View {
        // String interpolation keeps the catalog key "%@" (an Int would make it "%lld").
        let value = String(Int(nits.rounded()))
        Label {
            Text("The panel gives up to \(value) nit right now")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown in the popover only when there is something to act on.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        switch updates.state {
        case .available(let version):
            HStack {
                Label {
                    Text("Version \(version) is available")
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .font(.callout)
                Spacer()
                Button("Install") { updates.installUpdate() }
                    .controlSize(.small)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading update…").font(.caption) }
        case .installing:
            ProgressView { Text("Installing update…").font(.caption) }
                .progressViewStyle(.linear)
        default:
            EmptyView()
        }
    }
}

/// Standard / sustained / peak. Full macOS brightness equals the selected maximum.
struct BoostLevelPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Maximum brightness", selection: model.boostLevelBinding) {
                Text("Standard").tag(BoostLevel.off)
                Text(verbatim: "\(Int(model.maxNits(for: .sustained).rounded())) nit").tag(BoostLevel.sustained)
                Text(verbatim: "\(Int(model.maxNits(for: .peak).rounded())) nit").tag(BoostLevel.peak)
            }
            .pickerStyle(.segmented)

            Group {
                if let app = model.activeRuleAppName {
                    Text("Mode set for \(app)")
                } else if model.scheduleControlsLevel {
                    Text("Mode set by the schedule")
                } else {
                    Text("Full macOS brightness equals the selected maximum. Brightness keys work as usual.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
