import SwiftUI
import DisplayPanelCore

/// Presentation only. The production adapter supplies journal observations;
/// synthetic previews never construct a controller or authorize a write.
/// Qualification, scope and limits live in docs/display-disable.md#app-controls.
struct ExperimentalDisconnectPresentation: Equatable {
    enum Phase: CaseIterable {
        case leased, refused, helperFailed, watchdogRecovery, reconnectFailed
    }

    struct SyntheticSession: Equatable {
        let phase: Phase
        let target: DisplayIdentitySnapshot
        let journalID: String
        let journalPath: String
        let targetEnumerable: Bool
        let leaseSeconds: Int
        let elapsedSeconds: Int
        let failure: String?
    }

    static let summary = "Uses a private macOS API. Automation pauses until the reconnect is verified."
    static let docsURL = URL(string: "https://github.com/brettinternet/displaypanel/blob/main/docs/display-disable.md#app-controls")!

    let syntheticSession: SyntheticSession?
    static let production = Self(syntheticSession: nil)
    var canDisconnect: Bool { false }
    var canReconnect: Bool { false }

    var title: String {
        guard let session = syntheticSession else { return "Full disconnect" }
        switch session.phase {
        case .leased: return remainingSeconds == 0 ? "Reconnecting" : "Disconnected"
        case .refused: return "Disconnect refused"
        case .helperFailed: return "Recovery helper failed"
        case .watchdogRecovery: return "Reconnecting"
        case .reconnectFailed: return "Reconnect failed"
        }
    }

    var leaseIsValid: Bool {
        guard let session = syntheticSession else { return false }
        return (1...60).contains(session.leaseSeconds) && session.elapsedSeconds >= 0
    }

    var remainingSeconds: Int? {
        guard let session = syntheticSession, leaseIsValid else { return nil }
        return max(0, session.leaseSeconds - session.elapsedSeconds)
    }

    var detail: String {
        guard let session = syntheticSession else { return Self.summary }
        guard leaseIsValid else { return "Refused: the lease must be 1–60 seconds." }
        switch session.phase {
        case .leased:
            if remainingSeconds == 0 {
                return "Waiting for the helper to verify the reconnect."
            }
            return "Reconnects in \(remainingSeconds ?? 0) seconds."
        case .refused:
            return "The display’s identity is ambiguous, so DisplayPanel won’t guess."
        case .helperFailed:
            return "Reconnect, or check recovery details. The recovery journal is kept."
        case .watchdogRecovery:
            return "Reconnect requested. Not verified yet."
        case .reconnectFailed:
            return "DisplayPanel couldn’t verify the reconnect. The recovery journal is kept."
        }
    }

    /// Recovery details, shown collapsed.
    var evidence: [(label: String, value: String)] {
        guard let session = syntheticSession else { return [] }
        return [
            ("Display", "\(session.target.name ?? session.target.uuid)\n\(session.target.identityDetail)"
                + (session.targetEnumerable ? "" : "\nNot connected now")),
            ("Journal", session.journalPath),
            ("Journal ID", session.journalID),
        ]
    }
}

struct ExperimentalDisconnectView: View {
    let presentation: ExperimentalDisconnectPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title).font(.headline)
            Text(presentation.detail)
                .foregroundStyle(.secondary)
            if let remaining = presentation.remainingSeconds,
               let session = presentation.syntheticSession, session.phase == .leased {
                ProgressView(value: Double(session.leaseSeconds - remaining), total: Double(session.leaseSeconds))
                    .accessibilityLabel("Disconnect lease elapsed")
                    .accessibilityValue("\(remaining) seconds remaining")
            }
            if let failure = presentation.syntheticSession?.failure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !presentation.evidence.isEmpty {
                DisclosureGroup("Recovery details") {
                    ForEach(presentation.evidence, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Inspect") {
                        Text("dp recovery status").font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
