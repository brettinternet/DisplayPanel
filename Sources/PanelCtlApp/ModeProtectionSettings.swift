import SwiftUI
import PanelCtlCore

/// One display's saved mode and its protection switch, on that display's page.
struct ModeProtectionSettings: View {
    @ObservedObject var model: AppModel
    let tile: DisplayTile
    @State private var failure: String?

    var body: some View {
        if let uuid = tile.uuid, UUID(uuidString: uuid) != nil {
            let entry = model.modePreferences.displays.first { $0.id == uuid.lowercased() }
            Section {
                Toggle(isOn: Binding(
                    get: { entry?.enabled ?? false },
                    set: { enabled in perform { try model.setModeProtectionEnabled(uuid: uuid, enabled: enabled) } }
                )) {
                    Text("Restore saved mode")
                    Text(entry.map { Self.summary($0.saved.mode) } ?? "Remember the current mode first.")
                }
                .disabled(entry == nil)
                .accessibilityLabel("Restore saved mode for \(tile.name)")
                HStack {
                    Button("Remember Current Mode") { perform { try model.rememberCurrentMode(uuid: uuid) } }
                        .disabled(tile.display == nil || model.hideConfigurationFrozen || model.isBlackoutHidden(uuid))
                        .accessibilityLabel("Remember current mode for \(tile.name)")
                    if entry != nil {
                        Button("Forget") { perform { try model.forgetMode(uuid: uuid) } }
                            .accessibilityLabel("Forget saved mode for \(tile.name)")
                    }
                }
                if let problem = failure ?? model.modeStorageFailure {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let result = model.modeResults[uuid.lowercased()] {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Display mode")
            } footer: {
                SectionFooter("Restores the saved resolution, refresh rate and scale after a reconnect or wake, not after your own changes.",
                              learnMore: AppModel.modeProtectionDocsURL)
            }
        }
    }

    private static func summary(_ mode: RecoveryMode) -> String {
        var parts = ["\(mode.width) × \(mode.height)"]
        if mode.refreshRate > 0 {
            parts.append("\(mode.refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Hz")
        }
        if mode.pixelWidth > mode.width { parts.append("HiDPI") }
        return parts.joined(separator: " · ")
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
