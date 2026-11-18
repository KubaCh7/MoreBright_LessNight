import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaysSettingsView()
                .tabItem { Label("Displays", systemImage: "display") }
            AppRulesSettingsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 520, height: 520)
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
                Label("Maximum Brightness", systemImage: "sun.max.fill")
            } footer: {
                Text("Standard: the usual macOS range. 1000 nit: what the panel can sustain on a MacBook Pro. 1600 nit: peak brightness; macOS caps it when the panel or your Mac gets warm. The whole brightness range is scaled, so the lowest steps get brighter too.")
                    .foregroundStyle(.secondary)
            }

            ScheduleSection()

            Section {
                Toggle(isOn: $model.pauseForVideo) {
                    Label {
                        Text("Pause during video")
                    } icon: {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("HDR video already uses the extra brightness, and the boost would blow out its highlights. While a player or browser plays video, the boost pauses and comes back when playback stops. SDR video pauses it too: macOS doesn't tell apps whether a video is HDR.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Toggle full brightness", selection: $model.hotKeyChoice) {
                    ForEach(HotKeyChoice.allCases) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                }
            } header: {
                Label("Keyboard Shortcut", systemImage: "keyboard")
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
                Label("Safety", systemImage: "thermometer.medium")
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
                Link("Release Notes", destination: release.pageURL)
            }
        } header: {
            Label("Updates", systemImage: "arrow.down.circle.fill")
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
            Section {
                LabeledContent("Last automatic pause") {
                    if let pause = model.lastPause {
                        Text(verbatim: "\(pause.reason.title), \(pause.date.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("None")
                    }
                }
            } footer: {
                Text("If the screen ever dims on its own, this shows why.")
                    .foregroundStyle(.secondary)
            }
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
                if let nits = screen.limitedToNits { HeadroomLimitNote(nits: nits) }
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
                Picker("Technique", selection: $model.technique) {
                    Text("Transfer table (recommended)").tag(BoostTechnique.gammaTable)
                    Text("Multiply overlay").tag(BoostTechnique.overlay)
                }
            } header: {
                Label("Boost Technique", systemImage: "wand.and.stars")
            } footer: {
                Text("Transfer table: the boost is applied in the display pipeline, like BetterDisplay and Lunar, so ⌘Tab and Space swipes can't interrupt it. Multiply overlay: a full-screen window does the boost; screenshots and the color test can see it, but window animations can briefly dim it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Color Test…") { model.openColorTest() }
            } header: {
                Label("Diagnostics", systemImage: "stethoscope")
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

// MARK: - Schedule

/// Standard / sustained / peak options for any level picker.
struct LevelOptions: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text("Standard").tag(BoostLevel.off)
        Text(verbatim: "\(Int(model.maxNits(for: .sustained).rounded())) nit").tag(BoostLevel.sustained)
        Text(verbatim: "\(Int(model.maxNits(for: .peak).rounded())) nit").tag(BoostLevel.peak)
    }
}

private struct ScheduleSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: $model.scheduleEnabled) {
                Label {
                    Text("Schedule")
                } icon: {
                    Image(systemName: "sun.horizon.fill").symbolRenderingMode(.multicolor)
                }
            }
            if model.scheduleEnabled {
                Picker("Switch at", selection: $model.scheduleKind) {
                    Text("Sunrise and sunset").tag(ScheduleKind.sun)
                    Text("Custom times").tag(ScheduleKind.custom)
                }

                if model.scheduleKind == .sun {
                    if let times = model.todaysSunTimes {
                        LabeledContent("Sunrise today") { Text(times.sunrise, style: .time) }
                        LabeledContent("Sunset today") { Text(times.sunset, style: .time) }
                    } else if let error = model.location.lastError {
                        Text(verbatim: error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { model.location.refreshIfNeeded(force: true) }
                    } else {
                        Text("Waiting for your location…").foregroundStyle(.secondary)
                    }
                    Picker("After sunrise", selection: $model.dayLevel) { LevelOptions() }
                    Picker("After sunset", selection: $model.nightLevel) { LevelOptions() }
                } else {
                    DatePicker("Day starts at", selection: model.timeBinding(\.dayStartMinutes), displayedComponents: .hourAndMinute)
                    Picker("Day mode", selection: $model.dayLevel) { LevelOptions() }
                    DatePicker("Night starts at", selection: model.timeBinding(\.nightStartMinutes), displayedComponents: .hourAndMinute)
                    Picker("Night mode", selection: $model.nightLevel) { LevelOptions() }
                }
            }
        } header: {
            Label("Schedule", systemImage: "sunrise.fill")
        } footer: {
            Text("Switches the maximum brightness automatically. A manual change stays until the next switch, like Night Shift. Your location is used only to calculate sunrise and sunset, on this Mac.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Apps

struct AppRulesSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.appRules.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sortedRuleIDs, id: \.self) { bundleID in
                    HStack(spacing: 10) {
                        Image(nsImage: model.appIcon(bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Picker(selection: model.ruleBinding(bundleID)) {
                            LevelOptions()
                        } label: {
                            Text(verbatim: model.appName(bundleID))
                        }
                        Button {
                            model.setRule(bundleID, level: nil)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove"))
                    }
                }
            } header: {
                Label("App Rules", systemImage: "square.grid.2x2.fill")
            } footer: {
                Text("While one of these apps is in front, its mode replaces the selected maximum brightness, for example Standard for photo editing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Add App…") { model.addRuleFromPanel() }
                    if let id = model.lastForeignBundleID, model.appRules[id] == nil {
                        Button("Add \(model.appName(id))") { model.setRule(id, level: .off) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
