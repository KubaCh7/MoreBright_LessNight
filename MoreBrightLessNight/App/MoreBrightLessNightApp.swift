import SwiftUI

@main
struct MoreBrightLessNightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            // Template image by default in the menu bar; fill follows the brightest display.
            Image(systemName: "sun.max.fill", variableValue: model.iconLevel)
                .accessibilityLabel(Text(verbatim: "MoreBrightLessNight"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
