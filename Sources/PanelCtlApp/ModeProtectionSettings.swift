import SwiftUI
import PanelCtlCore

struct ModeProtectionSettings: View {
    @ObservedObject var model: AppModel
    @State private var failure: String?

    var body: some View {
        Section {
            DisclosureGroup("Mode protection") {
                ForEach(model.activeDisplays, id: \.id) { display in
                    if let uuid = display.uuid {
                        HStack {
                            Text(display.settingsName)
                            Spacer()
                            Button("Remember current mode") {
                                perform { try model.rememberCurrentMode(uuid: uuid) }
                            }
                            .disabled(model.hideConfigurationFrozen || model.isBlackoutHidden(uuid))
                        }
                    }
                }
                ForEach(model.modePreferences.displays) { entry in
                    VStack(alignment: .leading) {
                        Toggle("Protect \(entry.saved.name ?? entry.saved.uuid)", isOn: Binding(
                            get: { entry.enabled },
                            set: { enabled in perform { try model.setModeProtectionEnabled(uuid: entry.id, enabled: enabled) } }
                        ))
                        Text(entry.saved.mode.description).font(.caption).foregroundStyle(.secondary)
                        Button("Forget mode") { perform { try model.forgetMode(uuid: entry.id) } }
                        if let result = model.modeResults[entry.id] {
                            Text(result).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if let message = failure ?? model.modeStorageFailure {
                    Text(message).font(.caption).textSelection(.enabled)
                }
                Text("Off by default. Remember, then enable protection for each display. Restores exact resolution, refresh rate and scale once after reconnect or wake, before arrangement protection. Waits up to 15 seconds; never approximates. Ordinary System Settings edits stand. Session-only; no rotation, HDR or color profile changes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
