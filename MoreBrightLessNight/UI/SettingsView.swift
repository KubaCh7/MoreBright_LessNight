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
                Toggle("1600-nit mode (peak)", isOn: model.peakModeBinding)
            } header: {
                Text("Peak Brightness")
            } footer: {
                Text("Off: the full slider equals the brightness the panel can sustain (about 1000 nits on MacBook Pro). On: the full slider equals peak brightness (about 1600 nits). Peak mode turns itself off when your Mac gets warm.")
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
                Text(verbatim: String(format: "%.2f×", screen.effectiveGain)).monospacedDigit()
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
                    knee: screen.knee,
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
            Text("Used to place the slider's knee and cap the boost. The real output is always limited by the headroom macOS reports.")
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
