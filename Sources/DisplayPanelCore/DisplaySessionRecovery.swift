import Foundation

/// A confirmation is bound to the entire old journal and observed desktop, not
/// just its ID. It never grants authority to replay a previous boot's writes.
public struct DisplaySessionRecovery: Equatable {
    public let journalID: String
    public let journalIdentity: String
    public let topologyIdentity: String
    public let displayNames: [String]
    public let blocker: String?
    public let canAutomaticallyKeepShown: Bool

    public var canRecover: Bool { blocker == nil }
}

extension RecoveryJournal {
    /// Even false private-attempt fields are evidence, not public ownership.
    var isPublicMirrorOnly: Bool {
        (publicMirrorSession != nil || (mirrorTargetID != nil && mirrorSourceID != nil)) &&
            disabledByUsID == nil && disableAttempted == nil && disableStaged == nil &&
            disableCommitStarted == nil && disableCompleted == nil && reenableAttempted == nil &&
            privateRecoveryClosed == nil && privateLease == nil && watchdogPID == nil &&
            deadline == nil && !verifyOnly
    }

    var recoveryPairs: [(target: String, source: String)] {
        if let session = publicMirrorSession {
            return session.removals.filter { !$0.state.resolved }.map { ($0.targetUUID, $0.sourceUUID) }
        }
        guard let target = snapshot.displays.first(where: { $0.id == mirrorTargetID }),
              let source = snapshot.displays.first(where: { $0.id == mirrorSourceID }) else { return [] }
        return [(target.uuid, source.uuid)]
    }
}

extension MirrorController {
    func sessionRecovery(journal: RecoveryJournal, current: RecoverySnapshot,
                         available: [DisplayRecord]) -> DisplaySessionRecovery? {
        guard !journal.state.resolved, journal.isPublicMirrorOnly,
              journal.snapshot.bootSession != current.bootSession,
              let journalIdentity = stableRecoveryDigest(journal),
              let topologyIdentity = current.stableTopologyIdentity() else { return nil }
        let blocker: String?
        do {
            try validateCurrentDesktop(journal: journal, current: current, available: available)
            blocker = nil
        } catch { blocker = error.localizedDescription }
        let names = journal.recoveryPairs.map { pair in
            journal.snapshot.displays.first { $0.uuid == pair.target }?.name ?? pair.target
        }
        return DisplaySessionRecovery(
            journalID: journal.id.uuidString, journalIdentity: journalIdentity,
            topologyIdentity: topologyIdentity, displayNames: names, blocker: blocker,
            canAutomaticallyKeepShown: blocker == nil && sameDesktopAcrossBoot(journal.snapshot, current)
        )
    }

    private func validateCurrentDesktop(journal: RecoveryJournal, current: RecoverySnapshot,
                                        available: [DisplayRecord]) throws {
        guard !journal.state.resolved, journal.isPublicMirrorOnly,
              journal.snapshot.bootSession != current.bootSession else {
            throw RecoveryError.unsafe("only a previous-boot public Hide journal can be retired this way")
        }
        let baseline = journal.snapshot
        guard baseline.userID == current.userID, baseline.hostModel == current.hostModel else {
            throw RecoveryError.unsafe("the journal belongs to a different user or Mac; keep it for inspection")
        }
        guard !current.displays.isEmpty,
              Set(current.displays.map(\.uuid)).count == current.displays.count,
              Set(current.displays.map(\.id)).count == current.displays.count,
              Set(current.displays.map(\.uuid)) == Set(baseline.displays.map(\.uuid)),
              Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
              Set(available.filter(\.online).map(\.id)) == Set(current.displays.map(\.id)) else {
            throw RecoveryError.unsafe("reconnect all captured monitors to the Mac input; missing, extra or ambiguous displays cannot be accepted")
        }
        for saved in baseline.displays {
            guard let now = current.displays.first(where: { $0.uuid == saved.uuid }),
                  saved.vendor == now.vendor, saved.model == now.model, saved.serial == now.serial,
                  saved.builtin == now.builtin, saved.connector == now.connector,
                  saved.identityEvidence?.transport == now.identityEvidence?.transport,
                  saved.identityEvidence?.transportLocation == now.identityEvidence?.transportLocation,
                  let record = available.first(where: { $0.uuid?.lowercased() == saved.uuid }),
                  record.id == now.id, record.vendor == now.vendor, record.model == now.model,
                  record.serial == now.serial, record.builtin == now.builtin else {
                throw RecoveryError.unsafe("identity or connector changed for \(saved.name ?? saved.uuid); reconnect the captured monitor, not a replacement")
            }
            guard now.mirrorUUID == nil else {
                throw RecoveryError.unsafe("turn off mirroring for \(saved.name ?? saved.uuid) in System Settings → Displays, then Check Again")
            }
            guard now.active, record.online, record.active, !record.asleep else {
                throw RecoveryError.unsafe("\(saved.name ?? saved.uuid) is unavailable to macOS; return it to the Mac input or reconnect it, then Check Again")
            }
        }
        let pairs = journal.recoveryPairs
        let targets = Set(pairs.map(\.target))
        guard !pairs.isEmpty, targets.count == pairs.count,
              pairs.allSatisfy({ pair in
                  !targets.contains(pair.source) &&
                      current.displays.contains { $0.uuid == pair.target && !$0.builtin } &&
                      current.displays.contains { $0.uuid == pair.source }
              }), current.displays.filter(\.main).count == 1,
              current.displays.contains(where: { !targets.contains($0.uuid) }) else {
            throw RecoveryError.unsafe("the previous Hide set has no safe, separate mirror source; keep the journal")
        }
    }

    /// Numeric display/mode IDs are boot-local. All meaningful desktop
    /// properties must still match before automatic, no-write acceptance.
    private func sameDesktopAcrossBoot(_ baseline: RecoverySnapshot, _ current: RecoverySnapshot) -> Bool {
        guard baseline.osBuild == current.osBuild else { return false }
        return baseline.displays.allSatisfy { saved in
            guard let now = current.displays.first(where: { $0.uuid == saved.uuid }) else { return false }
            let a = saved.mode, b = now.mode
            return saved.active == now.active && saved.main == now.main &&
                saved.x == now.x && saved.y == now.y && saved.rotation == now.rotation &&
                saved.mirrorUUID == now.mirrorUUID && saved.colorSpace == now.colorSpace &&
                saved.hasSameColorProfile(as: now) &&
                a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth &&
                a.pixelHeight == b.pixelHeight && a.refreshRate == b.refreshRate && a.flags == b.flags
        }
    }

    func recoverCurrentDesktop(_ confirmation: DisplaySessionRecovery, hideAgain: Bool,
                               store: RecoveryStore) throws {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }
        try recoverCurrentDesktopLocked(confirmation, hideAgain: hideAgain, store: store)
    }

    /// Caller holds both locks. One stable preflight, one transaction at most;
    /// never restore the old baseline, send DDC, or retry a failed write.
    func recoverCurrentDesktopLocked(_ confirmation: DisplaySessionRecovery, hideAgain: Bool,
                                     automatic: Bool = false, store: RecoveryStore) throws {
        let old = try store.load()
        let current = try engine.capture()
        guard old.id.uuidString == confirmation.journalID,
              stableRecoveryDigest(old) == confirmation.journalIdentity,
              current.stableTopologyIdentity() == confirmation.topologyIdentity,
              let assessment = sessionRecovery(journal: old, current: current, available: try records()),
              assessment.canRecover else {
            throw RecoveryError.unsafe("journal or desktop changed since confirmation; Check Again before recovery")
        }
        guard !automatic || (!hideAgain && assessment.canAutomaticallyKeepShown) else {
            throw RecoveryError.unsafe("current desktop differs from the previous session; confirm Keep displays shown or Hide again")
        }
        func validateBeforeReplacement() throws {
            guard stableRecoveryDigest(try store.load()) == confirmation.journalIdentity else {
                throw RecoveryError.unsafe("journal changed before retirement; no recovery was started")
            }
            let observed = try engine.capture()
            try current.verify(observed)
            try validateCurrentDesktop(journal: old, current: observed, available: records())
        }
        engine.convergencePause()
        try validateBeforeReplacement()
        if hideAgain { try preflightModes(current) }
        var replacement = RecoveryJournal(snapshot: current)
        replacement.supersedesJournalID = old.id
        replacement.trigger = automatic ? "previous-session-desktop-matched" : "keep-displays-shown"
        replacement.state = .verified // Verifies the NEW baseline, never the old transaction.
        if hideAgain {
            let removals = old.recoveryPairs.map { pair in
                PublicMirrorRemoval(target: current.displays.first { $0.uuid == pair.target }!,
                                    source: current.displays.first { $0.uuid == pair.source }!,
                                    beforeOperation: current)
            }
            replacement.version = 3
            replacement.publicMirrorSession = PublicMirrorSession(baseline: current, removals: removals)
            replacement.state = .captured
            replacement.trigger = "hide-again"
        }
        try store.supersedePublicMirror(old, with: replacement, revalidate: validateBeforeReplacement)
        guard hideAgain, var session = replacement.publicMirrorSession else { return }
        let pendingIdentity = stableRecoveryDigest(replacement)
        do {
            try transaction.apply(removals: session.removals.map { ($0.targetID, $0.sourceID) }, origins: []) {
                let observed = try engine.capture()
                try current.verify(observed)
                try validateCurrentDesktop(journal: old, current: observed, available: records())
                guard stableRecoveryDigest(try store.load()) == pendingIdentity else {
                    throw RecoveryError.unsafe("new Hide journal changed before the write; keep recovery")
                }
            }
            try engine.converge {
                guard MirrorSessionTopology.matches(baseline: current, removals: session.removals,
                                                    current: try engine.capture()) else {
                    throw RecoveryError.unsafe("Hide again did not verify; keep the new recovery journal")
                }
            }
            guard stableRecoveryDigest(try store.load()) == pendingIdentity else {
                throw RecoveryError.unsafe("new Hide journal changed during verification; keep recovery")
            }
            for index in session.removals.indices { session.removals[index].state = .mirrored }
            replacement.publicMirrorSession = session
            replacement.state = .mirrored
            try store.save(replacement)
        } catch {
            if let saved = try? store.load(), stableRecoveryDigest(saved) == pendingIdentity {
                for index in session.removals.indices {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = error.localizedDescription
                }
                replacement.publicMirrorSession = session
                replacement.state = .needsAttention
                replacement.failure = error.localizedDescription
                try? store.save(replacement)
            }
            throw error
        }
    }
}
