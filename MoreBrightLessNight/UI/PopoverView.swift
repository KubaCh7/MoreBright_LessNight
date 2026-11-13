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

            Toggle(isOn: model.peakModeBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("1600-nit mode (peak)")
                    Group {
                        if model.peakAutoDisabled {
                            Text("Turned off automatically because your Mac got warm")
                        } else {
                            Text("Full slider uses peak instead of sustained brightness")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityHint(Text("Allows brightness up to the panel's peak level"))

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
                    knee: screen.knee,
                    accessibilityLabel: Text("Brightness for \(screen.name)")
                )
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
            Text("Highlights clipped: the panel can't show this level right now")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
