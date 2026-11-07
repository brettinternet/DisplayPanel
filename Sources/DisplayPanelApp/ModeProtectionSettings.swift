import SwiftUI
import DisplayPanelCore

/// One display's refresh rate, saved mode and protection switch, on that display's page.
struct ModeProtectionSettings: View {
    @ObservedObject var model: AppModel
    let tile: DisplayTile
    @State private var failure: String?

    var body: some View {
        if let uuid = tile.uuid, UUID(uuidString: uuid) != nil {
            let entry = model.modePreferences.displays.first { $0.id == uuid.lowercased() }
            let unavailable = tile.display == nil || model.hideConfigurationFrozen || model.isBlackoutHidden(uuid)
            Section {
                if let rates = model.refreshRates(uuid: uuid) {
                    Picker("Refresh rate", selection: Binding(
                        get: { rates.current.refreshRate },
                        set: { rate in
                            guard let mode = rates.choices.first(where: { $0.refreshRate == rate }) else { return }
                            Task {
                                do { try await model.setRefreshRate(uuid: uuid, to: mode); failure = nil }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    )) {
                        ForEach(rates.choices, id: \.refreshRate) { Text(AppModel.hertz($0.refreshRate)).tag($0.refreshRate) }
                    }
                    .disabled(unavailable)
                    .accessibilityLabel("Refresh rate for \(tile.name)")
                }
                Toggle(isOn: Binding(
                    get: { entry?.enabled ?? false },
                    set: { enabled in perform { try model.setModeProtectionEnabled(uuid: uuid, enabled: enabled) } }
                )) {
                    Text("Restore saved mode")
                    if let entry { Text(Self.summary(entry.saved.mode)) }
                }
                .disabled(entry == nil && unavailable)
                .accessibilityLabel("Restore saved mode for \(tile.name)")
                HStack {
                    Button("Remember Current Mode") { perform { try model.rememberCurrentMode(uuid: uuid) } }
                        .disabled(unavailable)
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
        if mode.refreshRate > 0 { parts.append(AppModel.hertz(mode.refreshRate)) }
        if mode.pixelWidth > mode.width { parts.append("HiDPI") }
        return parts.joined(separator: " · ")
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
