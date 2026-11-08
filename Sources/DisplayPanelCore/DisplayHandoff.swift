import Foundation

public struct DisplayHandoffIdentity: Equatable {
    public let uuid: String
    public let id: UInt32
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public var identityDetail: String {
        "Display ID \(id) · UUID \(uuid) · \(vendor):\(model):\(serial)"
    }

    public var detail: String { identityDetail }

    init(_ identity: DisplayHideIdentity) {
        uuid = identity.uuid
        id = identity.displayID
        name = identity.name
        vendor = identity.vendor
        model = identity.model
        serial = identity.serial
    }
}

public struct DisplayInputOutcome: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case notRequested
        case notAttempted
        case skipped
        case verified
        case alreadySelected
        case unverified
        case failed

        /// A write may have been sent, so the monitor may relink.
        var mayHaveSwitched: Bool { self == .verified || self == .unverified || self == .failed }
    }

    public let state: State
    public let requestedInput: UInt8?
    public let observedInput: UInt8?
    public let detail: String?
    public let recoveryCommand: String?

    public init(state: State, requestedInput: UInt8? = nil, observedInput: UInt8? = nil,
                detail: String? = nil, recoveryCommand: String? = nil) {
        self.state = state
        self.requestedInput = requestedInput
        self.observedInput = observedInput
        self.detail = detail
        self.recoveryCommand = recoveryCommand
    }

    public static let notRequested = Self(state: .notRequested)
}

public struct DisplayHandoffOperationFailure: Error, LocalizedError {
    public let action: String
    public let inputOutcome: DisplayInputOutcome
    /// Show together: each target's outcome, keyed by lowercase UUID.
    public let inputOutcomes: [String: DisplayInputOutcome]
    public let message: String

    public var errorDescription: String? { message }

    init(action: String, inputOutcome: DisplayInputOutcome, inputOutcomes: [String: DisplayInputOutcome] = [:],
         message: String) {
        self.action = action
        self.inputOutcome = inputOutcome
        self.inputOutcomes = inputOutcomes
        self.message = message
    }
}

public struct DisplayHandoffRemoval: Equatable, Identifiable {
    public let id: String
    public let target: DisplayHandoffIdentity
    public let source: DisplayHandoffIdentity
    public let state: String
    public let isUnresolved: Bool
    public let canShow: Bool
    public let reason: String?
    public let topologyVerified: Bool

    public init(id: String, target: DisplayHandoffIdentity, source: DisplayHandoffIdentity,
                state: String, isUnresolved: Bool, canShow: Bool, reason: String?, topologyVerified: Bool) {
        self.id = id
        self.target = target
        self.source = source
        self.state = state
        self.isUnresolved = isUnresolved
        self.canShow = canShow
        self.reason = reason
        self.topologyVerified = topologyVerified
    }
}

/// A display Turn off disconnected. It has no mirror source.
public struct DisplayHandoffTurnOff: Equatable, Identifiable {
    public let id: String
    public let target: DisplayHandoffIdentity
    public let state: String
    public let isUnresolved: Bool
    public let canShow: Bool
    public let reason: String?

    public init(id: String, target: DisplayHandoffIdentity, state: String,
                isUnresolved: Bool, canShow: Bool, reason: String?) {
        self.id = id
        self.target = target
        self.state = state
        self.isUnresolved = isUnresolved
        self.canShow = canShow
        self.reason = reason
    }
}

public struct DisplayHandoffStatus: Equatable {
    public enum State: Equatable {
        case none
        case hidden
        case recovery
        case unsupported
        case busy
    }

    public let state: State
    public let target: DisplayHandoffIdentity?
    public let source: DisplayHandoffIdentity?
    public let journalPath: String
    public let journalID: String?
    public let reason: String?
    public let canShow: Bool
    public let inspectionCommand: String
    public let recoveryCommand: String?
    public let observations: [DisplayHideObservation]
    public let inspectionFailure: String?
    public let mirrorTopologyVerified: Bool
    /// Stable normalized digest of the journaled baseline, retained after inspection reconciliation.
    public let baselineIdentity: String?
    /// Stable journal/session digest, excluding capture-time and diagnostic-only data.
    public let journalIdentity: String?
    /// Stable normalized digest of the latest observation; exact checks still use RecoverySnapshot.verify.
    public let observedTopologyIdentity: String?
    public let removals: [DisplayHandoffRemoval]
    /// Kept apart from removals: a turned-off display has no source and is never hidden again.
    public let turnedOff: [DisplayHandoffTurnOff]
    public let sessionRecovery: DisplaySessionRecovery?

    public var hasUnresolvedJournal: Bool {
        removals.contains(where: \.isUnresolved) || turnedOff.contains(where: \.isUnresolved) || state != .none
    }
    public func turnedOff(for uuid: String) -> DisplayHandoffTurnOff? {
        turnedOff.first { $0.target.uuid.caseInsensitiveCompare(uuid) == .orderedSame && $0.isUnresolved }
    }
    public func removal(for uuid: String) -> DisplayHandoffRemoval? {
        if let removal = removals.first(where: { $0.target.uuid.caseInsensitiveCompare(uuid) == .orderedSame && $0.isUnresolved }) {
            return removal
        }
        guard state != .none, let target, let source,
              target.uuid.caseInsensitiveCompare(uuid) == .orderedSame else { return nil }
        return DisplayHandoffRemoval(
            id: journalID ?? target.uuid, target: target, source: source,
            state: state == .hidden ? "mirrored" : "needsAttention", isUnresolved: true, canShow: canShow,
            reason: reason, topologyVerified: mirrorTopologyVerified
        )
    }

    init(
        state: State,
        target: DisplayHandoffIdentity? = nil,
        source: DisplayHandoffIdentity? = nil,
        journalPath: String,
        journalID: String? = nil,
        reason: String? = nil,
        canShow: Bool = false,
        recoveryCommand: String? = nil,
        observations: [DisplayHideObservation] = [],
        inspectionFailure: String? = nil,
        mirrorTopologyVerified: Bool = false,
        baselineIdentity: String? = nil,
        observedTopologyIdentity: String? = nil,
        journalIdentity: String? = nil,
        removals: [DisplayHandoffRemoval] = [],
        turnedOff: [DisplayHandoffTurnOff] = [],
        sessionRecovery: DisplaySessionRecovery? = nil
    ) {
        self.state = state
        self.target = target
        self.source = source
        self.journalPath = journalPath
        self.journalID = journalID
        self.reason = reason
        self.canShow = canShow
        self.inspectionCommand = "dp recovery status --journal \(Self.shellQuote(journalPath))"
        self.recoveryCommand = recoveryCommand
        self.observations = observations
        self.inspectionFailure = inspectionFailure
        self.mirrorTopologyVerified = mirrorTopologyVerified
        self.baselineIdentity = baselineIdentity
        self.observedTopologyIdentity = observedTopologyIdentity
        self.journalIdentity = journalIdentity
        self.removals = removals
        self.turnedOff = turnedOff
        self.sessionRecovery = sessionRecovery
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HiddenMirrorSourceOverlayAuthorization {
    /// Ordinary targets need the same whole-session verification as source overlays.
    static func sessionRefusal(
        status: DisplayHandoffStatus,
        isMirrored: (UInt32) -> Bool
    ) -> String? {
        let sources = status.removals.isEmpty
            ? status.source.map { [$0] } ?? []
            : status.removals.filter(\.isUnresolved).map(\.source)
        guard !sources.isEmpty else { return "the removal session has no verified mirror sources" }
        for source in sources {
            if let reason = refusal(sourceUUID: source.uuid, sourceDisplayID: source.id,
                                    isMirrored: isMirrored(source.id), status: status) {
                return reason
            }
        }
        return nil
    }

    static func revalidateSessionWhileCovered(
        status: DisplayHandoffStatus,
        isMirrored: (UInt32) -> Bool,
        removeCoverage: () -> Void
    ) -> String? {
        guard let reason = sessionRefusal(status: status, isMirrored: isMirrored) else { return nil }
        removeCoverage()
        return reason
    }

    static func refusal(
        sourceUUID: String,
        sourceDisplayID: UInt32,
        isMirrored: Bool,
        status: DisplayHandoffStatus
    ) -> String? {
        guard isMirrored else { return "the selected display is no longer in a mirror set" }
        guard status.inspectionFailure == nil, status.state == .hidden,
              status.canShow, status.journalID != nil, status.mirrorTopologyVerified else {
            return status.reason ?? "the shared journal does not verify every removal in this Hidden layout"
        }
        let removals: [DisplayHandoffRemoval]
        if !status.removals.isEmpty {
            removals = status.removals.filter(\.isUnresolved)
        } else if let target = status.target, let source = status.source {
            removals = [DisplayHandoffRemoval(
                id: status.journalID ?? target.uuid, target: target, source: source,
                state: "mirrored", isUnresolved: true, canShow: status.canShow,
                reason: status.reason, topologyVerified: status.mirrorTopologyVerified
            )]
        } else {
            return "the shared journal has no verified removal entries"
        }
        guard !removals.isEmpty, removals.allSatisfy({ $0.canShow && $0.topologyVerified }),
              removals.contains(where: {
                  $0.source.uuid.caseInsensitiveCompare(sourceUUID) == .orderedSame && $0.source.id == sourceDisplayID
              }) else {
            return "the shared journal does not verify this selected source as a source for a healthy removal"
        }
        for removal in removals {
            let targets = status.observations.filter {
                $0.isJournalTarget && $0.identity.uuid.caseInsensitiveCompare(removal.target.uuid) == .orderedSame
            }
            guard targets.count == 1, let target = targets.first,
                  target.state == .hiddenByDisplayPanel,
                  target.identity.displayID == removal.target.id,
                  target.source?.uuid.caseInsensitiveCompare(removal.source.uuid) == .orderedSame,
                  target.source?.displayID == removal.source.id else {
                return "a journaled target is not observed mirroring its recorded source"
            }
        }
        guard let selectedSource = removals.first(where: {
            $0.source.uuid.caseInsensitiveCompare(sourceUUID) == .orderedSame && $0.source.id == sourceDisplayID
        })?.source else {
            return "the selected display is not a source in the journal"
        }
        let sourceObservations = status.observations.filter {
            $0.identity.uuid.caseInsensitiveCompare(selectedSource.uuid) == .orderedSame
        }
        guard sourceObservations.count == 1, let sourceObservation = sourceObservations.first,
              sourceObservation.state == .separate,
              sourceObservation.identity.displayID == selectedSource.id,
              sourceObservation.identity.vendor == selectedSource.vendor,
              sourceObservation.identity.model == selectedSource.model,
              sourceObservation.identity.serial == selectedSource.serial else {
            return "the current selected source identity or topology does not match the journal"
        }
        let targetUUIDs = Set((removals.map(\.target) + status.turnedOff.filter(\.isUnresolved).map(\.target))
            .map { $0.uuid.lowercased() })
        guard status.observations.allSatisfy({ observation in
            observation.state == .separate ||
                (observation.isJournalTarget && targetUUIDs.contains(observation.identity.uuid.lowercased()) &&
                 observation.state == .hiddenByDisplayPanel)
        }) else {
            return "another display is externally mirrored or has unknown recovery state"
        }
        return nil
    }

    static func revalidateWhileCovered(
        sourceUUID: String,
        sourceDisplayID: UInt32,
        isMirrored: Bool,
        status: DisplayHandoffStatus,
        removeCoverage: () -> Void
    ) -> String? {
        guard let reason = refusal(
            sourceUUID: sourceUUID,
            sourceDisplayID: sourceDisplayID,
            isMirrored: isMirrored,
            status: status
        ) else {
            return nil
        }
        removeCoverage()
        return reason
    }
}

/// Optional monitor input selection around journal-backed public mirroring.
public enum DisplayHandoff {
    public static var defaultJournalPath: String { RecoveryStore.defaultURL.path }

    public static func run(selector: String, source: String?, input: UInt8?, journalPath: String?) throws {
        let store = RecoveryStore(url: journalPath.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
        let controller = HandoffController(mirror: .production)
        if let source {
            try controller.away(selector: selector, source: source, input: input, store: store)
        } else {
            try controller.back(selector: selector, input: input, store: store)
        }
    }

    /// Reads the shared default journal under the same operation/journal locks
    /// as CLI writers. Exact observed restoration may resolve a mirror journal;
    /// preservingMirrorIntent leaves journal state untouched during automatic
    /// re-link settlement. Neither path writes display topology or monitor input.
    public static func inspect(preservingMirrorIntent: Bool = false) -> DisplayHandoffStatus {
        let status: DisplayHideStatus
        do {
            status = try DisplayHideController().inspect(preservingMirrorIntent: preservingMirrorIntent)
        } catch {
            let path = defaultJournalPath
            let message = error.localizedDescription
            let busy = message.localizedCaseInsensitiveContains("busy") ||
                message.localizedCaseInsensitiveContains("lock already held")
            return DisplayHandoffStatus(
                state: busy ? .busy : .recovery,
                journalPath: path,
                reason: message,
                recoveryCommand: "dp recovery status --journal \(DisplayHandoffStatus.shellQuote(path))",
                inspectionFailure: message
            )
        }
        return handoffStatus(from: status)
    }

    static func handoffStatus(from status: DisplayHideStatus) -> DisplayHandoffStatus {
        guard let journal = status.journal else {
            return DisplayHandoffStatus(
                state: .none, journalPath: status.journalPath,
                observations: status.observations, inspectionFailure: status.inspectionFailure
            )
        }
        guard journal.isMirrorJournal else {
            return DisplayHandoffStatus(
                state: journal.isUnresolved ? .unsupported : .none,
                target: journal.target.map(DisplayHandoffIdentity.init),
                journalPath: status.journalPath, journalID: journal.id,
                reason: journal.showRefusal ?? status.inspectionFailure,
                recoveryCommand: nil, observations: status.observations,
                inspectionFailure: status.inspectionFailure,
                baselineIdentity: journal.baselineIdentity,
                observedTopologyIdentity: journal.observedTopologyIdentity,
                journalIdentity: journal.journalIdentity
            )
        }
        var removals = journal.removals.map { removal in
            DisplayHandoffRemoval(
                id: removal.id, target: DisplayHandoffIdentity(removal.target),
                source: DisplayHandoffIdentity(removal.source), state: removal.state,
                isUnresolved: removal.isUnresolved, canShow: removal.canShow,
                reason: removal.showRefusal ?? removal.failure,
                topologyVerified: removal.topologyVerified
            )
        }
        if removals.isEmpty, let target = journal.target, let source = journal.source {
            removals = [DisplayHandoffRemoval(
                id: journal.id, target: DisplayHandoffIdentity(target), source: DisplayHandoffIdentity(source),
                state: journal.state, isUnresolved: journal.isUnresolved, canShow: journal.canShow,
                reason: journal.showRefusal, topologyVerified: journal.mirrorTopologyVerified
            )]
        }
        let turnedOff = status.turnedOff.map { off in
            DisplayHandoffTurnOff(
                id: off.id, target: DisplayHandoffIdentity(off.target), state: off.state,
                isUnresolved: off.isUnresolved, canShow: off.canShow, reason: off.showRefusal ?? off.failure
            )
        }
        let unresolved = removals.filter(\.isUnresolved)
        let unresolvedOff = turnedOff.filter(\.isUnresolved)
        let attention = unresolved.first(where: { !$0.topologyVerified || !$0.canShow })
        let offAttention = unresolvedOff.first(where: { !$0.canShow })
        let primary = attention ?? unresolved.first
        // A turned-off target never pairs with a source, so removal(for:) can't invent a mirror for it.
        let primaryOff = attention == nil && (offAttention != nil || unresolved.isEmpty)
            ? offAttention ?? unresolvedOff.first : nil
        let state: DisplayHandoffStatus.State = !journal.isUnresolved ? .none
            : attention == nil && offAttention == nil ? .hidden : .recovery
        let reason = attention?.reason ?? offAttention?.reason ?? journal.failure ?? journal.showRefusal ??
            status.inspectionFailure ?? status.observations.first(where: \.isJournalTarget)?.detail
        let targets = unresolved.map(\.target) + unresolvedOff.map(\.target)
        let recoveryCommand: String?
        if targets.count == 1, let target = targets.first {
            recoveryCommand = "dp recovery restore --display \(DisplayHandoffStatus.shellQuote(target.uuid)) --journal \(DisplayHandoffStatus.shellQuote(status.journalPath))"
        } else if targets.count > 1 {
            recoveryCommand = "dp recovery status --journal \(DisplayHandoffStatus.shellQuote(status.journalPath))"
        } else {
            recoveryCommand = nil
        }
        return DisplayHandoffStatus(
            state: state,
            target: primaryOff?.target ?? primary?.target ?? journal.target.map(DisplayHandoffIdentity.init),
            source: primaryOff != nil ? nil : primary?.source ?? journal.source.map(DisplayHandoffIdentity.init),
            journalPath: status.journalPath, journalID: journal.id, reason: reason,
            canShow: unresolved.contains(where: \.canShow) || unresolvedOff.contains(where: \.canShow),
            recoveryCommand: recoveryCommand,
            observations: status.observations, inspectionFailure: status.inspectionFailure,
            mirrorTopologyVerified: journal.mirrorTopologyVerified,
            baselineIdentity: journal.baselineIdentity,
            observedTopologyIdentity: journal.observedTopologyIdentity,
            journalIdentity: journal.journalIdentity, removals: removals, turnedOff: turnedOff,
            sessionRecovery: status.sessionRecovery
        )
    }
}

struct HandoffController {
    var mirror = MirrorController()
    var open: (String, Bool) throws -> (display: DDC.DisplayTarget, channel: DDCChannel) = {
        try DDC.open(selector: $0, allowInactive: $1)
    }
    var select: (UInt8, DDCChannel, UInt32, String, UInt8?) throws -> DDCInputSelection = {
        try DDCInput.select($0, channel: $1, displayID: $2, uuid: $3, original: $4, readOriginal: false)
    }
    var report: (String) -> Void = { print($0) }
    var reselectPause: () -> Void = { Thread.sleep(forTimeInterval: 4) }

    func guardedAway(target: DisplayHideIdentity, source: DisplayHideIdentity, input: UInt8?,
                     wakeExpectation: DisplayHideWakeExpectation? = nil,
                     store: RecoveryStore) throws -> DisplayInputOutcome {
        var inputOutcome = input.map {
            DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                detail: "Input selection was not attempted because Hide did not reach the captured handoff step.")
        } ?? .notRequested
        do {
            _ = try mirror.mirror(
                selector: target.uuid,
                source: source.uuid,
                store: store,
                expectedTarget: target,
                expectedSource: source,
                wakeExpectation: wakeExpectation
            ) { capturedTarget in
                guard input != nil else { return }
                let outcome = selectInput(input, target: capturedTarget)
                inputOutcome = outcome
                if outcome.state == .failed {
                    throw RecoveryError.unsafe(outcome.detail ?? "DDC input selection failed")
                }
            }
            return inputOutcome
        } catch {
            throw DisplayHandoffOperationFailure(action: "hide", inputOutcome: inputOutcome,
                                                 message: error.localizedDescription)
        }
    }

    func guardedBack(expectedJournalID: UUID, targetUUID: String? = nil, input: UInt8?,
                     store: RecoveryStore) throws -> DisplayInputOutcome {
        var inputOutcome = input.map {
            DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                detail: "Input selection was not attempted because Show did not pass journal and display validation.")
        } ?? .notRequested
        do {
            var inputAttempted = false
            var previousInput: UInt8?
            let returnInput: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)? = input == nil ? nil : { target in
                inputAttempted = true
                inputOutcome = selectInput(input, target: target, returning: true, willSelect: { previous, _ in
                    previousInput = previous
                })
                return inputOutcome.state
            }
            let relinkInput: ((RecoveryDisplay) throws -> Bool)? = input == nil ? nil : { target in
                guard [.verified, .unverified].contains(inputOutcome.state), let input, let previousInput,
                      let back = reselect(input, through: previousInput, target: target) else { return false }
                inputOutcome = back
                guard back.state != .failed else { throw RecoveryError.unsafe(back.detail ?? "DDC selection failed") }
                return true
            }
            _ = try mirror.unmirror(
                store: store,
                selector: targetUUID,
                expectedID: expectedJournalID,
                noOpWhenAlreadyResolved: true,
                returnInputBeforeRestore: returnInput,
                relinkInput: relinkInput
            )
            if let input, !inputAttempted {
                inputOutcome = DisplayInputOutcome(
                    state: .notAttempted,
                    requestedInput: input,
                    detail: "Input selection was not attempted because the journal was already resolved; duplicate Show did not send DDC."
                )
            }
            return inputOutcome
        } catch {
            let inputDetail = inputOutcome.detail.map { " Input return: \($0)" } ?? ""
            throw DisplayHandoffOperationFailure(action: "show", inputOutcome: inputOutcome,
                                                 message: error.localizedDescription + inputDetail)
        }
    }

    /// Show together. `inputs` maps each target's lowercase UUID to its Mac input;
    /// a target without one keeps its monitor's input.
    func guardedBackAll(expectedJournalID: UUID, inputs: [String: UInt8],
                        store: RecoveryStore) throws -> [String: DisplayInputOutcome] {
        var outcomes = inputs.mapValues {
            DisplayInputOutcome(state: .notAttempted, requestedInput: $0,
                                detail: "Input selection was not attempted because Show did not pass journal and display validation.")
        }
        var previousInputs: [String: UInt8] = [:]
        do {
            _ = try mirror.unmirrorAll(store: store, expectedID: expectedJournalID, returnInputBeforeRestore: { target in
                let key = target.uuid.lowercased()
                guard let input = inputs[key] else { return .notRequested }
                let outcome = selectInput(input, target: target, returning: true, willSelect: { previous, _ in
                    previousInputs[key] = previous
                })
                outcomes[key] = outcome
                return outcome.state
            }, relinkInput: { target in
                let key = target.uuid.lowercased()
                guard let state = outcomes[key]?.state, [.verified, .unverified].contains(state),
                      let input = inputs[key], let previous = previousInputs[key],
                      let back = reselect(input, through: previous, target: target) else { return false }
                outcomes[key] = back
                guard back.state != .failed else { throw RecoveryError.unsafe(back.detail ?? "DDC selection failed") }
                return true
            })
            return outcomes
        } catch {
            let inputDetail = outcomes.values.compactMap(\.detail).filter { !$0.hasPrefix("Input selection was not attempted") }
                .map { " Input return: \($0)" }.joined()
            throw DisplayHandoffOperationFailure(action: "show", inputOutcome: .notRequested, inputOutcomes: outcomes,
                                                 message: error.localizedDescription + inputDetail)
        }
    }

    func away(selector: String, source: String, input: UInt8?, store: RecoveryStore) throws {
        var inputRecovery: String?
        var capturedTarget: RecoveryDisplay?
        do {
            _ = try mirror.mirror(selector: selector, source: source, store: store) { target in
                capturedTarget = target
                try switchInput(input, target: target) { inputRecovery = $0 }
            }
            report("Hidden by mirroring; the Mac still drives the monitor. Journal: \(store.url.path)")
            guard let target = capturedTarget else {
                throw RecoveryError.unsafe("newly hidden target is missing from the durable journal; inspect recovery status")
            }
            report("Return with: dp back --display \(shellQuote(target.uuid)) --consent-back --journal \(shellQuote(store.url.path))")
            report("Add --input <Mac input> to switch the monitor back over DDC, or use the monitor's input button.")
        } catch {
            throw RecoveryError.unsafe("\(error)\(inputRecovery.map { ". Input recovery: \($0)" } ?? "")")
        }
    }

    func back(selector: String, input: UInt8?, store: RecoveryStore) throws {
        var inputFailure: Error?
        var previousInput: UInt8?
        var returned: DisplayInputOutcome.State?
        let returnInput: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)? = input == nil ? nil : { target in
            do {
                let state = try switchInput(input, target: target, returning: true, previous: { previousInput = $0 }) {
                    report("Input recovery: \($0)")
                }
                returned = state
                return state
            } catch {
                inputFailure = error
                return .failed
            }
        }
        let relinkInput: ((RecoveryDisplay) throws -> Bool)? = input == nil ? nil : { target in
            guard returned == .verified || returned == .unverified, let input, let previousInput,
                  let back = reselect(input, through: previousInput, target: target) else { return false }
            report("Re-selected the Mac input through \(MonitorInput.name(previousInput)) to relink the monitor.")
            guard back.state != .failed else {
                throw RecoveryError.unsafe("\(back.detail ?? "DDC selection failed"); retry back or use the monitor's input button")
            }
            return true
        }
        let journal: RecoveryJournal
        do {
            journal = try mirror.unmirror(store: store, selector: selector, returnInputBeforeRestore: returnInput,
                                          relinkInput: relinkInput)
        } catch {
            throw RecoveryError.unsafe(error.localizedDescription + (inputFailure.map { " Input return: \($0.localizedDescription)" } ?? ""))
        }
        if let inputFailure { throw inputFailure }
        if input == nil { report("No --input given; use the monitor's input button.") }
        let remaining = journal.publicMirrorSession?.removals.filter { !$0.state.resolved }.count ?? 0
        if remaining > 0 {
            report("Shown and verified; \(remaining) more still hidden. Positions may shift slightly until the last one is shown. Journal: \(store.url.path)")
        } else {
            report("Shown; arrangement restored and verified. Journal: \(store.url.path)")
        }
    }

    /// Some monitors keep a dead link when the Mac retrains it while they show
    /// another input: the return to the Mac input then neither hotplugs nor
    /// shows a picture, but re-selecting it through the previous input does.
    /// An unconfirmed return qualifies too (S2721DGF): either way this ends on
    /// the Mac input, through the input read before the return.
    /// Returns the final selection, or nil when no write was sent.
    func reselect(_ input: UInt8, through previous: UInt8, target: RecoveryDisplay) -> DisplayInputOutcome? {
        guard selectInput(previous, target: target, returning: true).state.mayHaveSwitched else { return nil }
        reselectPause()
        return selectInput(input, target: target, returning: true)
    }

    func selectInput(_ input: UInt8?, target: RecoveryDisplay, returning: Bool = false,
                     willSelect: (_ previous: UInt8, _ command: String) -> Void = { _, _ in }) -> DisplayInputOutcome {
        guard let input else { return .notRequested }
        guard input > 0 else {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Input code 0 is invalid; choose dp1, dp2, hdmi1, hdmi2, or a value from 1 through 255.")
        }
        do {
            let records = try mirror.records()
            guard matchesCapturedIdentity(target, records: records) else {
                return staleInputTarget(target, requested: input, actual: "current display inventory")
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Could not verify the captured DDC target identity: \(error.localizedDescription)")
        }

        let session: (display: DDC.DisplayTarget, channel: DDCChannel)
        do {
            session = try open(target.uuid, returning)
        } catch {
            do {
                guard try matchesCapturedIdentity(target, records: mirror.records()) else {
                    return staleInputTarget(target, requested: input, actual: "current display inventory")
                }
            } catch {
                return DisplayInputOutcome(state: .failed, requestedInput: input,
                                           detail: "Could not verify the captured DDC target identity after opening failed: \(error.localizedDescription)")
            }
            return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                       detail: "DDC is unavailable: \(error.localizedDescription). Use the monitor's input button.")
        }
        guard session.display.id == target.id,
              session.display.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame else {
            return staleInputTarget(target, requested: input, actual: "opened DDC display ID \(session.display.id), UUID \(session.display.uuid)")
        }
        do {
            guard try matchesCapturedIdentity(target, records: mirror.records()) else {
                return staleInputTarget(target, requested: input, actual: "current display inventory after opening DDC")
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "Could not revalidate the captured DDC target identity: \(error.localizedDescription)")
        }

        let original: UInt8?
        do {
            let reading = try DDCInput.current(session.channel)
            guard reading != 0 else {
                return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                           detail: "DDC returned unknown input 0. Use the monitor's input button.")
            }
            original = reading
        } catch {
            guard returning else {
                return DisplayInputOutcome(state: .skipped, requestedInput: input,
                                           detail: "DDC input could not be read: \(error.localizedDescription). Use the monitor's input button.")
            }
            // A monitor on an inactive input may stop answering Get VCP while
            // still accepting Set VCP. Return to the known Mac input once;
            // never invent a previous input or a switch-back command.
            original = nil
        }
        let command = original.map {
            "dp ddc-input --display \(shellQuote(target.uuid)) --set \(String(format: "0x%02X", $0))"
        }
        if let original, let command { willSelect(original, command) }
        do {
            let result = try select(input, session.channel, target.id, target.uuid, original)
            switch result.outcome {
            case .alreadySelected:
                return DisplayInputOutcome(state: .alreadySelected, requestedInput: input,
                                           observedInput: result.observed, recoveryCommand: command)
            case .verified:
                return DisplayInputOutcome(state: .verified, requestedInput: input,
                                           observedInput: result.observed, recoveryCommand: command)
            case .unverified:
                return DisplayInputOutcome(state: .unverified, requestedInput: input,
                                           observedInput: result.observed, detail: result.detail,
                                           recoveryCommand: command)
            }
        } catch {
            return DisplayInputOutcome(state: .failed, requestedInput: input,
                                       detail: "DDC selection failed: \(error.localizedDescription)",
                                       recoveryCommand: command)
        }
    }

    private func matchesCapturedIdentity(_ target: RecoveryDisplay, records: [DisplayRecord]) -> Bool {
        let matches = records.filter { $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame }
        guard matches.count == 1, let record = matches.first else { return false }
        return record.id == target.id && record.vendor == target.vendor &&
            record.model == target.model && record.serial == target.serial
    }

    private func staleInputTarget(_ target: RecoveryDisplay, requested: UInt8, actual: String) -> DisplayInputOutcome {
        DisplayInputOutcome(
            state: .failed,
            requestedInput: requested,
            detail: "DDC target identity changed since capture (expected Display ID \(target.id), UUID \(target.uuid), vendor/model/serial \(target.vendor)/\(target.model)/\(target.serial); found \(actual). Refresh Displays and use the exact captured monitor; no input was selected."
        )
    }

    @discardableResult
    private func switchInput(_ input: UInt8?, target: RecoveryDisplay, returning: Bool = false,
                             previous: (UInt8) -> Void = { _ in },
                             recovery: (String) -> Void) throws -> DisplayInputOutcome.State {
        let outcome = selectInput(input, target: target, returning: returning, willSelect: { original, command in
            previous(original)
            recovery(command + ", or use the monitor's input button")
            report("To reverse input selection: \(command), or use the monitor's input button.")
        })
        switch outcome.state {
        case .notRequested:
            report("No --input given; use the monitor's input button.")
        case .notAttempted:
            report("Input not switched: \(outcome.detail ?? "unknown reason").")
        case .skipped:
            report("Input not switched (\(outcome.detail ?? "DDC unavailable")); use the monitor's input button.")
        case .verified, .alreadySelected, .unverified:
            let name = MonitorInput.name(outcome.observedInput ?? outcome.requestedInput ?? 0)
            report(outcome.state == .alreadySelected ? "The monitor was already on \(name)."
                : "Switched the monitor to \(name)\(outcome.state == .unverified ? "; not confirmed" : "")."
                + (outcome.detail.map { " \($0)" } ?? ""))
            if outcome.state == .unverified {
                report("Input switch is unverified; check visually and use the monitor's input button if needed.")
            }
        case .failed:
            throw RecoveryError.unsafe("\(outcome.detail ?? "DDC selection failed")\(outcome.recoveryCommand.map { ". Input recovery: \($0), or use the monitor's input button" } ?? "")")
        }
        return outcome.state
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
