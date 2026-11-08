import SwiftUI
import DisplayPanelCore

struct ExperimentalDisconnectControls: View {
    @ObservedObject var model: AppModel
    @State private var reconnectConsent = false
    @State private var reconnectJournalID: String?

    /// Shown whenever a disconnect journal exists or is unreadable, so reconnect
    /// stays reachable until recovery is verified.
    static func isVisible(model: AppModel) -> Bool {
        model.disconnectInspectionFailure != nil || model.disconnectStatus?.resolved == false
    }

    var body: some View {
        Section {
            if let failure = model.disconnectInspectionFailure {
                Text("Can’t read disconnect recovery. Automation stays paused.")
                Text("\(model.disconnectJournalPath)").font(.caption).textSelection(.enabled)
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
                Button("Reconnect…") {}.disabled(true)
                LabeledContent("Inspect recovery") {
                    Text("dp recovery status").font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let status = model.disconnectStatus {
                if status.resolved {
                    Text("Reconnected. If the screen stays dark, select this Mac’s input on the monitor.")
                } else if let presentation = presentation(status) {
                    ExperimentalDisconnectView(presentation: presentation)
                } else {
                    Text("The helper stopped before recording a display. Automation stays paused; check recovery status.")
                    Text("\(status.journalPath) · \(status.state)").font(.caption).textSelection(.enabled)
                    if let failure = status.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                }
                if !status.resolved {
                    Button("Reconnect…") {
                        reconnectJournalID = status.journalID
                        reconnectConsent = true
                    }
                    .disabled(!status.canReconnect || model.disconnectInspectionFailure != nil)
                }
            }
            if let failure = model.disconnectFailure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.protectionQuiescenceFailure != nil {
                Button("Retry Automation Cleanup", action: model.retryAutomationCleanup)
                    .disabled(model.protectionQuiescencePending)
            }
        } header: {
            Text("Full disconnect")
        } footer: {
            SectionFooter(ExperimentalDisconnectPresentation.summary, learnMore: ExperimentalDisconnectPresentation.docsURL)
        }
        .alert("Reconnect the display?", isPresented: $reconnectConsent) {
            Button("Reconnect") {
                if let reconnectJournalID { model.reconnectDisconnect(expectedJournalID: reconnectJournalID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the screen stays dark, select this Mac’s input on the monitor.")
        }
    }

    private func presentation(_ status: DisplayDisconnectStatus) -> ExperimentalDisconnectPresentation? {
        guard let target = status.target else { return nil }
        let phase: ExperimentalDisconnectPresentation.Phase
        if status.state == "needsAttention" {
            phase = status.trigger == "helper-error" ? .helperFailed : .reconnectFailed
        } else if status.state == "restoring" { phase = .watchdogRecovery }
        else { phase = .leased }
        let elapsed = max(0, min(3600, model.countdownDate.timeIntervalSince(status.createdAt)))
        let duration = status.deadline?.timeIntervalSince(status.createdAt) ?? 15
        return .init(syntheticSession: .init(phase: phase,
            target: .init(uuid: target.uuid, id: target.displayID, name: target.name,
                          vendor: target.vendor, model: target.model, serial: target.serial),
            journalID: status.journalID, journalPath: status.journalPath,
            targetEnumerable: model.displays.contains { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame },
            leaseSeconds: Int(duration), elapsedSeconds: Int(elapsed), failure: status.failure))
    }
}
