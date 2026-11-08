import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    static let experimentalConsentTitle = "Turn on experimental features?"
    static let experimentalConsentMessage = "Hide can mirror a display, switch the monitor’s input or turn the display off. Windows, resolution, refresh rate and HDR may change until Show."

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: model.setLaunchAtLogin
                ))
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { model.showMenuBarIcon },
                    set: model.setShowMenuBarIcon
                ))
            } footer: {
                SectionFooter("With the icon hidden, open DisplayPanel again to return here.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.experimentalFeaturesEnabled },
                    set: model.setExperimentalFeaturesEnabled
                )) {
                    Text("Experimental features")
                    Text("Hide styles Mirror, Switch input and Turn off.")
                }
                Link("Learn more", destination: AppModel.experimentalDocsURL)
            }

            Section {
                LabeledContent("Version") {
                    Text(model.version)
                        .textSelection(.enabled)
                }
                Link("View on GitHub", destination: AppModel.githubURL)
                Button("Quit DisplayPanel") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}
