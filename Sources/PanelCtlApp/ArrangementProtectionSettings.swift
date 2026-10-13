import SwiftUI
import PanelCtlCore

struct ArrangementProtectionSettings: View {
    @ObservedObject var model: AppModel
    @State private var failure: String?

    var body: some View {
        let status = model.arrangementStatus
        Section {
            DisclosureGroup("Arrangement protection") {
                Toggle("Protect remembered arrangements", isOn: Binding(
                    get: { model.arrangementPreferences.enabled },
                    set: model.setArrangementProtectionEnabled
                ))
                .accessibilityLabel("Protect remembered arrangements")
                Toggle("Apply on launch", isOn: Binding(
                    get: { model.arrangementPreferences.applyOnLaunch },
                    set: model.setArrangementApplyOnLaunch
                ))
                .accessibilityLabel("Apply arrangement on launch")
                .disabled(!model.arrangementPreferences.enabled)
                Picker("Preferred main", selection: Binding(
                    get: { model.arrangementPreferences.preferredMain?.uuid.lowercased() ?? "" },
                    set: { uuid in perform { try model.setArrangementPreferredMain(uuid: uuid.isEmpty ? nil : uuid) } }
                )) {
                    Text("None").tag("")
                    ForEach(model.activeDisplays.filter { !model.isBlackoutHidden($0.uuid) }, id: \.id) { display in
                        if let uuid = display.uuid { Text(display.settingsName).tag(uuid.lowercased()) }
                    }
                    if let preferred = model.arrangementPreferences.preferredMain,
                       !model.activeDisplays.contains(where: { $0.uuid?.caseInsensitiveCompare(preferred.uuid) == .orderedSame && !model.isBlackoutHidden($0.uuid) }) {
                        Text("\(preferred.name ?? preferred.uuid) (unavailable)").tag(preferred.uuid.lowercased())
                    }
                }
                Text(status.reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.differs {
                    Text("The current arrangement differs. Choose Remember current to replace the saved one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Remember current") { perform { try model.rememberCurrentArrangement() } }
                        .disabled(!status.canRemember)
                    Button("Restore arrangement") { _ = model.restoreArrangement() }
                        .disabled(!status.canRestore)
                }
                ForEach(model.arrangementPreferences.remembered, id: \.setKey) { arrangement in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(arrangement.members.map { $0.name ?? String($0.uuid.prefix(8)) }.joined(separator: ", "))
                            if let main = arrangement.members.first(where: \.main) {
                                Text("Main: \(main.name ?? main.uuid)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Forget") { perform { try model.forgetArrangement(setKey: arrangement.setKey) } }
                            .accessibilityLabel("Forget arrangement for \(arrangement.members.count) displays")
                    }
                }
                if let message = failure ?? model.arrangementLastResult {
                    Text(message).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Applies once after reconnect or wake, not after ordinary layout edits. Remembered sets take precedence over preferred main. Changes are session-only.")
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
