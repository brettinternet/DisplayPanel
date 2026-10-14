import SwiftUI
import PanelCtlCore

/// Arrangement protection covers every display, so it sits once under the
/// display tiles rather than on each display's page.
struct ArrangementStatusRow: View {
    @ObservedObject var model: AppModel
    @State private var presented = false

    var body: some View {
        let preferences = model.arrangementPreferences
        if model.activeDisplays.count > 1 || preferences.enabled ||
            !preferences.remembered.isEmpty || preferences.preferredMain != nil {
            let status = model.arrangementStatus
            let summary = summary(status)
            HStack(spacing: 8) {
                Label(summary.text, systemImage: summary.protected ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
                    .help(status.reason)
                Spacer(minLength: 8)
                Button("Arrangement…") { presented = true }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .sheet(isPresented: $presented) {
                ArrangementProtectionSettings(model: model)
            }
        }
    }

    private func summary(_ status: AppControlArrangementStatus) -> (text: String, protected: Bool) {
        guard model.arrangementPreferences.enabled else { return ("Arrangement protection is off", false) }
        switch status.state {
        case "remembered":
            return (status.differs ? "Arrangement protected · current layout differs" : "Arrangement protected", true)
        case "preferred-main": return ("Main display protected", true)
        case "suspended": return ("Arrangement protection paused", false)
        default: return ("These displays have no remembered arrangement", false)
        }
    }
}

struct ArrangementProtectionSettings: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        let status = model.arrangementStatus
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.arrangementPreferences.enabled },
                        set: model.setArrangementProtectionEnabled
                    )) {
                        Text("Protect remembered arrangements")
                        Text("Applies once after a reconnect or wake, not after your own layout changes.")
                    }
                    Toggle("Also apply on launch", isOn: Binding(
                        get: { model.arrangementPreferences.applyOnLaunch },
                        set: model.setArrangementApplyOnLaunch
                    ))
                    .disabled(!model.arrangementPreferences.enabled)
                    preferredMainPicker
                } header: {
                    Text("Arrangement protection")
                } footer: {
                    SectionFooter("A remembered arrangement for the connected displays takes precedence over the preferred main display. Changes are session-only.",
                                  learnMore: AppModel.arrangementDocsURL)
                }

                Section {
                    Text(status.reason)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.differs {
                        Text("The current arrangement differs from the remembered one. Remember it to replace the saved one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Remember Current Arrangement") { perform { try model.rememberCurrentArrangement() } }
                            .disabled(!status.canRemember)
                        Button("Restore") { failure = nil; _ = model.restoreArrangement() }
                            .disabled(!status.canRestore)
                            .accessibilityLabel("Restore arrangement")
                    }
                    if let message = failure ?? model.arrangementLastResult {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Connected displays")
                }

                Section("Remembered") {
                    if model.arrangementPreferences.remembered.isEmpty {
                        Text("No remembered arrangements.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.arrangementPreferences.remembered, id: \.setKey) { arrangement in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                // Left to right, like the display tiles.
                                Text(arrangement.members.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
                                    .map { $0.name ?? String($0.uuid.prefix(8)) }.joined(separator: ", "))
                                if let main = arrangement.members.first(where: \.main) {
                                    Text("Main: \(main.name ?? main.uuid)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Forget") { perform { try model.forgetArrangement(setKey: arrangement.setKey) } }
                                .accessibilityLabel("Forget arrangement for \(arrangement.members.count) displays")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
    }

    private var preferredMainPicker: some View {
        let choices = model.activeDisplays.filter { !model.isBlackoutHidden($0.uuid) }
        return Picker("Preferred main display", selection: Binding(
            get: { model.arrangementPreferences.preferredMain?.uuid.lowercased() ?? "" },
            set: { uuid in perform { try model.setArrangementPreferredMain(uuid: uuid.isEmpty ? nil : uuid) } }
        )) {
            Text("None").tag("")
            ForEach(choices, id: \.id) { display in
                if let uuid = display.uuid { Text(display.settingsName).tag(uuid.lowercased()) }
            }
            if let preferred = model.arrangementPreferences.preferredMain,
               !choices.contains(where: { $0.uuid?.caseInsensitiveCompare(preferred.uuid) == .orderedSame }) {
                Text("\(preferred.name ?? preferred.uuid) (unavailable)").tag(preferred.uuid.lowercased())
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
