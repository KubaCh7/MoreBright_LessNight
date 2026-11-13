import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaysSettingsView()
                .tabItem { Label("Displays", systemImage: "display") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 500, height: 460)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                if let error = model.launchAtLoginError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Only when connected to power", isOn: $model.onlyOnACPower)
            }

            Section {
                BoostLevelPicker()
            } header: {
                Text("Maximum Brightness")
            } footer: {
                Text("Standard: the usual macOS range. 1000 nit: what the panel can sustain on a MacBook Pro. 1600 nit: peak brightness, lowered to 1000 nit automatically when your Mac gets warm. The whole brightness range is scaled, so the lowest steps get brighter too.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Toggle full brightness", selection: $model.hotKeyChoice) {
                    ForEach(HotKeyChoice.allCases) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("The brightness keys keep working normally and the slider follows them.")
                    .foregroundStyle(.secondary)
            }

            UpdateSettingsSection(updates: model.updates)

            Section {
                LabeledContent("Thermal state") {
                    Text(verbatim: model.thermalState.localizedName)
                }
                LabeledContent("Power source") {
                    if model.power.isOnACPower {
                        Text("Power adapter")
                    } else if let battery = model.power.batteryPercent {
                        Text(verbatim: "\(battery) %")
                    } else {
                        Text("Battery")
                    }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("The extra brightness turns off automatically when the thermal state is serious, when the battery is under 20 percent and while the display sleeps.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Section {
            LabeledContent("Current version") {
                Text(verbatim: updates.currentVersion).monospacedDigit()
            }
            Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
            HStack {
                status
                Spacer()
                if case .available = updates.state {
                    Button("Install and Relaunch") { updates.installUpdate() }
                } else {
                    Button("Check Now") { updates.checkNow() }
                        .disabled(updates.isBusy)
                }
            }
            if let release = updates.availableRelease {
                Link("Release Notes", destination: release.htmlUrl)
            }
        } header: {
            Text("Updates")
        } footer: {
            if let lastChecked = updates.lastChecked {
                Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            Text("MoreBrightLessNight is up to date.").foregroundStyle(.secondary)
        case .available(let version):
            Text("Version \(version) is available")
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading update…") }
        case .installing:
            Text("Installing update…")
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Displays

struct DisplaysSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            ForEach(model.screens) { screen in
                DisplaySettingsSection(screen: screen)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettingsSection: View {
    @ObservedObject var screen: ScreenController

    var body: some View {
        Section {
            LabeledContent("Status") { StatusLabel(status: screen.status) }
            LabeledContent("Potential EDR headroom") {
                Text(verbatim: String(format: "%.2f×", screen.potentialHeadroom)).monospacedDigit()
            }
            LabeledContent("Current EDR headroom") {
                Text(verbatim: String(format: "%.2f×", screen.currentHeadroom)).monospacedDigit()
            }
            LabeledContent("Requested gain") {
                Text(verbatim: String(format: "%.2f×", screen.requestedGain)).monospacedDigit()
            }
            LabeledContent("Applied gain") {
                Text(verbatim: String(format: "%.2f×", screen.appliedGain)).monospacedDigit()
            }
            LabeledContent("Overlay") {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if screen.overlayIsPresenting, let age = screen.secondsSinceLastFrame {
                        Text(verbatim: String(format: "%.0f ms", age * 1000)).monospacedDigit()
                    } else {
                        Text("Stopped")
                    }
                }
            }
            LabeledContent("System brightness") {
                if let brightness = screen.systemBrightness {
                    Text(brightness, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                } else {
                    Text("Not available")
                }
            }
            if screen.supportsEDR {
                BrightnessSlider(
                    value: Binding(get: { screen.position }, set: { screen.setPosition($0) }),
                    accessibilityLabel: Text("Brightness for \(screen.name)")
                )
                if screen.highlightsClipped { ClippedWarning() }
            }
        } header: {
            Text(verbatim: screen.name)
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            ForEach(model.screens.filter(\.supportsEDR)) { screen in
                NitsProfileSection(screen: screen)
            }

            Section {
                Button("Open Color Test…") { model.openColorTest() }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Shows reference patches and measures the color difference with and without the boost.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NitsProfileSection: View {
    @ObservedObject var screen: ScreenController

    var body: some View {
        Section {
            TextField("System maximum (nits)", value: field(\.sdrNits), format: .number)
            TextField("Sustained (nits)", value: field(\.sustainedNits), format: .number)
            TextField("Peak (nits)", value: field(\.peakNits), format: .number)
            Button("Restore Defaults") { screen.updateProfile(.xdrDefault) }
        } header: {
            Text(verbatim: screen.name)
        } footer: {
            Text("Sets how many nits full macOS brightness means in each mode. The real output is always limited by the headroom macOS reports.")
                .foregroundStyle(.secondary)
        }
    }

    private func field(_ keyPath: WritableKeyPath<NitsProfile, Double>) -> Binding<Double> {
        Binding(
            get: { screen.profile[keyPath: keyPath] },
            set: { newValue in
                var profile = screen.profile
                profile[keyPath: keyPath] = newValue
                screen.updateProfile(profile)
            }
        )
    }
}
