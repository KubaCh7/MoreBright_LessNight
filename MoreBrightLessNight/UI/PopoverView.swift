import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Display Brightness")
                .font(.headline)

            if model.screens.isEmpty {
                Text("No displays found")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.screens) { screen in
                ScreenBrightnessRow(screen: screen)
            }

            Divider()

            BoostLevelPicker()

            Toggle("Pause during video", isOn: $model.pauseForVideo)
                .toggleStyle(.switch)

            if let reason = model.pauseReason {
                Label(reason.title, systemImage: reason.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            UpdateBanner(updates: model.updates)

            Divider()

            HStack {
                Button("Color Test…") { model.openColorTest() }
                Spacer()
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct ScreenBrightnessRow: View {
    @ObservedObject var screen: ScreenController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: screen.name)
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
        .accessibilityElement(children: .contain)
    }
}

struct StatusLabel: View {
    let status: ScreenStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
            .labelStyle(.titleAndIcon)
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
