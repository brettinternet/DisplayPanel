import Foundation

/// Turn off: a Hide style that drops the Mac's signal to one display for this
/// login session with the private setter (see docs/display-disable.md). It
/// shares the Hide session journal with mirror removals. Only an explicit
/// Turn off writes `enabled = false`; wake, relaunch and quit never do.
enum DisplayTurnOff {
    static let unavailable = "Turn off is unavailable"
    static let didNotReturn = "The display didn't turn back on. Select the Mac's input on the monitor or replug its cable."
    /// Read-only observations, 0.2 seconds apart, for macOS to drop or return a display.
    static let settleAttempts = 50

    /// Fresh refusals for turning off `target` from the private `capture`.
    /// Main is allowed; another usable physical display must stay on.
    static func refusals(target: RecoveryDisplay, capture: RecoverySnapshot, session: PublicMirrorSession?,
                         environment: RecoveryEligibilityEnvironment, awake: Bool) -> [String] {
        var reasons: [String] = []
        if environment.architecture != .appleSilicon { reasons.append("Apple Silicon required") }
        if environment.drivers != .nativeOnly { reasons.append("DisplayLink, virtual or unknown driver state") }
        if !awake { reasons.append("the Mac, its session or a display isn't awake") }
        if Set(capture.displays.map(\.id)) != Set(environment.screens.keys) {
            reasons.append("physical observations and online displays disagree")
        }
        // Unknown classification anywhere can't be treated as benign.
        for display in capture.displays where environment.screens[display.id]?.kind == .unknown {
            reasons.append("display \(display.id): unknown physical classification")
        }
        if target.builtin { reasons.append("built-in displays can't be turned off") }
        if target.mirrorUUID != nil || !target.active { reasons.append("the display is hidden or mirrored") }
        if capture.displays.contains(where: { $0.mirrorUUID?.caseInsensitiveCompare(target.uuid) == .orderedSame }) {
            reasons.append("another display mirrors this one")
        }
        if let session {
            if !session.unresolvedDisconnects.isEmpty { reasons.append("another display is turned off; Show it first") }
            // macOS can drop Hide mirrors when a display turns off (26B123).
            if !MirrorSessionTopology.activeRemovals(session.removals).isEmpty {
                reasons.append("a display is removed from the desktop; Show it first")
            }
        }
        reasons += RecoveryEligibilityPolicy.unusableReasons(target, environment: environment)
        let survivors = capture.displays.filter {
            $0.uuid != target.uuid && $0.active && $0.mirrorUUID == nil &&
                RecoveryEligibilityPolicy.unusableReasons($0, environment: environment).isEmpty
        }
        if survivors.isEmpty { reasons.append("no other usable physical display stays on") }
        return reasons
    }
}

/// Production reads and the verified setter. MirrorController has none by
/// default, so tests can't reach the private setter without a fake.
struct DisplayTurnOffBackend {
    var capture: () throws -> RecoverySnapshot
    var inventory: (RecoverySnapshot) throws -> RecoveryEnableInventory
    var environment: (RecoverySnapshot) throws -> RecoveryEligibilityEnvironment
    var awake: () -> Bool
    var transaction: () throws -> RecoveryEnableTransaction

    static let production = Self(
        capture: { try .capture() },
        inventory: { try RecoveryProductionProviders.identityInventory(for: $0) },
        environment: { try RecoveryProductionProviders.eligibilityEnvironment(current: $0) },
        awake: { RecoveryProductionProviders.lifecycleObservation().awake == true },
        transaction: { try RecoveryDisplayBinding.resolve().transaction() }
    )

    /// Exact identity of one saved display, online or absent. Other displays
    /// are left out so identical peers elsewhere don't block it.
    func requireIdentity(_ target: RecoveryDisplay, session saved: RecoverySnapshot) throws {
        let snapshot = RecoverySnapshot(bootSession: saved.bootSession, osBuild: saved.osBuild, userID: saved.userID,
                                        displays: [target], hostModel: saved.hostModel)
        let evidence = try inventory(snapshot)
        let scoped = RecoveryEnableInventory(
            bootSession: evidence.bootSession, osBuild: evidence.osBuild, userID: evidence.userID,
            identities: evidence.identities, onlineIDs: evidence.onlineIDs.intersection([target.id]),
            hostModel: evidence.hostModel, architecture: evidence.architecture, binding: evidence.binding
        )
        try RecoveryIdentityPolicy.evaluate(snapshot: snapshot, evidence: scoped).requireEligible()
    }
}

extension MirrorController {
    /// The app and CLI controller; only it can reach the private setter.
    static var production: Self {
        var controller = Self()
        controller.turnOffBackend = .production
        return controller
    }

    /// Turns off the confirmed display. Durable intent precedes the one
    /// private write, which is never retried.
    func turnOff(_ expected: DisplayHideIdentity, store: RecoveryStore) throws -> RecoveryJournal {
        guard let backend = turnOffBackend else { throw RecoveryError.unsafe(DisplayTurnOff.unavailable) }
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }

        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
              let record = available.first(where: { matches(expected, record: $0) }),
              record.online, record.active, !record.asleep, !record.builtin else {
            throw RecoveryError.unsafe("Turn off needs the confirmed external display awake on the desktop; refresh Displays and try again")
        }
        let current = try engine.capture()
        guard Set(current.displays.map(\.id)) == Set(available.filter(\.online).map(\.id)) else {
            throw RecoveryError.unsafe("display set changed during capture; try again")
        }
        var existing = try store.exists() ? store.load() : nil
        if var unresolved = existing, !unresolved.state.resolved {
            try adoptRenumbering(&unresolved, current: current, store: store)
            existing = unresolved
        }
        var journal: RecoveryJournal
        var session: PublicMirrorSession
        if let existing, !existing.state.resolved {
            guard let previous = existing.publicMirrorSession, existing.isPublicMirrorOnly,
                  previous.removals.allSatisfy({ $0.state != .needsAttention && $0.state != .captured && $0.state != .restoring }),
                  previous.unresolvedDisconnects.isEmpty,
                  MirrorSessionTopology.matches(previous, current: current) else {
                throw RecoveryError.unsafe("display recovery needs attention; resolve it before turning off a display")
            }
            journal = existing
            session = previous
        } else {
            guard current.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
                throw RecoveryError.unsafe("existing mirrors are present; refusing to start a Hide session")
            }
            session = PublicMirrorSession(baseline: current, removals: [])
            journal = RecoveryJournal(snapshot: current)
        }
        guard let saved = session.baseline.displays.first(where: { $0.id == record.id }),
              saved.uuid.caseInsensitiveCompare(expected.uuid) == .orderedSame,
              saved.vendor == expected.vendor, saved.model == expected.model, saved.serial == expected.serial else {
            throw RecoveryError.unsafe("selection changed during capture; try again")
        }
        let existingSession = journal.publicMirrorSession

        func check() throws -> RecoveryDisplay {
            let capture = try backend.capture()
            guard Set(capture.displays.map(\.id)) == Set(current.displays.map(\.id)),
                  let target = capture.displays.first(where: { $0.uuid == saved.uuid && $0.id == saved.id }),
                  target.vendor == saved.vendor, target.model == saved.model, target.serial == saved.serial else {
                throw RecoveryError.unsafe("display set or identity changed; nothing was turned off")
            }
            let refusals = DisplayTurnOff.refusals(target: target, capture: capture, session: existingSession,
                                                   environment: try backend.environment(capture),
                                                   awake: backend.awake())
            guard refusals.isEmpty else {
                throw RecoveryError.unsafe("Turn off refused: " + refusals.joined(separator: "; "))
            }
            try backend.requireIdentity(target, session: capture)
            return target
        }
        let target = try check()
        // Resolve the verified setter before recording any intent.
        let transaction = try backend.transaction()

        let previousState = existing?.state.resolved == false ? journal.state : RecoveryState.restored
        let disconnect = SessionDisconnect(target: target)
        session.disconnects = (session.disconnects ?? []) + [disconnect]
        journal.version = 3
        journal.publicMirrorSession = session
        journal.state = .captured
        journal.trigger = "turn-off"
        journal.failure = nil
        if existing == nil || existing?.state.resolved == true {
            try store.create(journal)
        } else {
            try store.save(journal)
        }
        func update(_ state: SessionDisconnectState, failure: String?) {
            journal.setDisconnect(disconnect.id, state, failure: failure)
        }

        var committing = false
        do {
            try transaction.configure(id: target.id, enabled: false, willCommit: {
                update(.off, failure: nil)
                journal.state = .mirrored
                try store.save(journal)
                committing = true
            }, revalidate: {
                try current.verify(engine.capture())
                guard try check().id == target.id, Self.sameStoredJournal(journal, try store.load()) else {
                    throw RecoveryError.unsafe("journal or display changed; nothing was turned off")
                }
            })
        } catch where !committing {
            update(.cancelled, failure: nil)
            journal.state = previousState
            journal.failure = RecoveryError.reason(of: error)
            try? store.save(journal)
            throw error
        } catch {
            update(.off, failure: RecoveryError.reason(of: error))
            journal.failure = RecoveryError.reason(of: error)
            try? store.save(journal)
            throw error
        }
        // macOS may apply its saved arrangement for the remaining displays,
        // including another main (seen on 26B123). Keep that arrangement but
        // give main back with one public write, as dragging the menu bar
        // would. Positions return on Show. A turned-off main has no role to
        // keep: macOS picks the next main.
        let others = current.excluding([target.uuid])
        let moved = RecoveryError.unsafe("It turned off, but macOS changed the other displays. Show it to put them back.")
        do {
            var previous: String?
            let observed = try settle {
                let observed = try engine.capture()
                let identity = observed.stableTopologyIdentity()
                defer { previous = identity }
                guard !observed.displays.contains(where: { $0.uuid == target.uuid }),
                      (try? others.validateRestoration(to: observed)) != nil,
                      identity != nil, identity == previous else {
                    throw RecoveryError.unsafe("The display didn't turn off.")
                }
                return observed
            }
            if !target.main, let savedMain = current.displays.first(where: \.main),
               let main = observed.displays.first(where: { $0.uuid == savedMain.uuid }),
               !main.main, main.active, main.mirrorUUID == nil {
                let origins = try observed.displays.filter { $0.active && $0.mirrorUUID == nil }
                    .sorted { $0.uuid != main.uuid && $1.uuid == main.uuid }
                    .map { display -> (UInt32, Int32, Int32) in
                        guard let x = Int32(exactly: Int64(display.x) - Int64(main.x)),
                              let y = Int32(exactly: Int64(display.y) - Int64(main.y)) else { throw moved }
                        return (display.id, x, y)
                    }
                do {
                    try self.transaction.apply(removals: [], origins: origins) { try observed.verify(engine.capture()) }
                } catch { throw moved }
            }
            try engine.converge {
                guard let session = journal.publicMirrorSession,
                      MirrorSessionTopology.matches(session, current: try engine.capture()) else { throw moved }
            }
        } catch {
            // Commit ran: keep `off` so Show can reconnect the saved ID once.
            update(.off, failure: RecoveryError.reason(of: error))
            journal.failure = RecoveryError.reason(of: error)
            try? store.save(journal)
            throw error
        }
        return journal
    }

    /// Show for a turned-off display. Caller holds both locks and has adopted
    /// renumbering and reconciled. An absent display gets exactly one private
    /// reconnect by its saved ID; an online one (macOS turned it back on, or a
    /// reconnect already ran) is only put back publicly.
    func showTurnedOff(_ journal: inout RecoveryJournal, disconnectID: UUID, store: RecoveryStore) throws -> RecoveryJournal {
        guard let session = journal.publicMirrorSession,
              let disconnect = session.disconnects?.first(where: { $0.id == disconnectID }) else {
            throw RecoveryError.unsafe("turned-off display entry disappeared; keep the journal")
        }
        func update(_ state: SessionDisconnectState, failure: String?) {
            journal.setDisconnect(disconnectID, state, failure: failure)
        }
        var current = try engine.capture()
        if !current.displays.contains(where: { $0.uuid == disconnect.targetUUID }) {
            guard disconnect.state == .off else {
                throw RecoveryError.unsafe(disconnect.failure ?? DisplayTurnOff.didNotReturn)
            }
            guard let backend = turnOffBackend else { throw RecoveryError.unsafe(DisplayTurnOff.unavailable) }
            let before = current
            func check() throws {
                guard !before.displays.contains(where: { $0.id == disconnect.targetID }) else {
                    throw RecoveryError.unsafe("another display now has the turned-off display's ID. \(DisplayTurnOff.didNotReturn)")
                }
                guard backend.awake() else { throw RecoveryError.unsafe("the Mac, its session or a display isn't awake") }
                try backend.requireIdentity(disconnect.target, session: session.baseline)
            }
            try check()
            let transaction = try backend.transaction()
            update(.reconnecting, failure: nil)
            journal.state = .restoring
            journal.trigger = "show-turned-off"
            journal.failure = nil
            try store.save(journal)
            var committing = false
            do {
                try transaction.configure(id: disconnect.targetID, enabled: true, willCommit: { committing = true }, revalidate: {
                    try before.verify(engine.capture())
                    try check()
                    guard Self.sameStoredJournal(journal, try store.load()) else {
                        throw RecoveryError.unsafe("journal changed before reconnect; inspect recovery status")
                    }
                })
            } catch where !committing {
                // Nothing was written: the one reconnect is still available.
                update(.off, failure: RecoveryError.reason(of: error))
                journal.state = .mirrored
                journal.failure = RecoveryError.reason(of: error)
                try? store.save(journal)
                throw error
            } catch {
                // Completion may have reconnected it anyway; observe, never repeat.
            }
            var previous: String?
            do {
                current = try settle {
                    let observed = try engine.capture()
                    let identity = observed.stableTopologyIdentity()
                    defer { previous = identity }
                    guard let back = observed.displays.first(where: { $0.uuid == disconnect.targetUUID }),
                          back.vendor == disconnect.target.vendor, back.model == disconnect.target.model,
                          back.serial == disconnect.target.serial, !back.builtin,
                          identity != nil, identity == previous else {
                        throw RecoveryError.unsafe(DisplayTurnOff.didNotReturn)
                    }
                    return observed
                }
            } catch {
                update(.needsAttention, failure: DisplayTurnOff.didNotReturn)
                try? store.save(journal)
                throw error
            }
            try adoptRenumbering(&journal, current: current, store: store)
        }
        return try restoreTurnedOn(&journal, disconnectID: disconnectID, current: current, store: store)
    }

    /// Puts an online turned-off display back: the whole baseline when nothing
    /// else is hidden, otherwise only its mode, origin and main role.
    private func restoreTurnedOn(_ journal: inout RecoveryJournal, disconnectID: UUID, current: RecoverySnapshot,
                                 store: RecoveryStore) throws -> RecoveryJournal {
        guard let session = journal.publicMirrorSession,
              let index = session.disconnects?.firstIndex(where: { $0.id == disconnectID }) else {
            throw RecoveryError.unsafe("turned-off display entry disappeared; keep the journal")
        }
        let targetUUID = session.disconnects![index].targetUUID
        var restored = session
        restored.disconnects![index].state = .restored
        restored.disconnects![index].failure = nil
        let last = MirrorSessionTopology.activeRemovals(session.removals).isEmpty && restored.unresolvedDisconnects.isEmpty
        do {
            let available = try records()
            guard let record = available.first(where: { $0.uuid?.caseInsensitiveCompare(targetUUID) == .orderedSame }),
                  record.online, !record.asleep,
                  MirrorSessionTopology.matches(session, current: current) else {
                throw RecoveryError.unsafe("current topology does not match the recorded session; nothing was changed")
            }
            journal.state = .restoring
            journal.trigger = "show-turned-off"
            try store.save(journal)
            if last {
                try preflightModes(session.baseline)
                if (try? session.baseline.verify(current)) == nil { try engine.apply(session.baseline) }
                try engine.converge { try session.baseline.verify(engine.capture()) }
            } else {
                let view = session.visible(in: current)
                try preflightModes(MirrorSessionTopology.showModeBaseline(view.baseline, removals: view.removals,
                                                                          showing: targetUUID, current: current))
                try restoreTarget(view.baseline, targetUUID, { try current.verify(engine.capture()) },
                                  { try engine.capture() })
                try engine.converge {
                    let observed = try engine.capture()
                    guard MirrorSessionTopology.showSurvivorsUnchanged(baseline: session.baseline, targetUUID: targetUUID,
                                                                       before: current, current: observed),
                          MirrorSessionTopology.matches(restored, current: observed) else {
                        throw RecoveryError.unsafe("Show changed another display or did not restore this one; keep recovery")
                    }
                }
            }
        } catch {
            journal.setDisconnect(disconnectID, .needsAttention, failure: RecoveryError.reason(of: error))
            try? store.save(journal)
            throw error
        }
        journal.publicMirrorSession = restored
        let attention = restored.removals.first(where: { !$0.state.resolved && $0.state == .needsAttention }).map(\.failure)
        journal.state = last ? .restored : (attention == nil ? .mirrored : .needsAttention)
        journal.failure = attention ?? nil
        try store.save(journal)
        return journal
    }

    /// Read-only observation for up to DisplayTurnOff.settleAttempts samples. Never writes.
    private func settle<T>(_ check: () throws -> T) throws -> T {
        var attempt = 1
        while true {
            do { return try check() } catch {
                guard attempt < DisplayTurnOff.settleAttempts else { throw error }
                attempt += 1
                engine.convergencePause()
            }
        }
    }
}

extension RecoveryJournal {
    /// Updates one Turn off entry; needsAttention also flags the journal.
    mutating func setDisconnect(_ id: UUID, _ state: SessionDisconnectState, failure: String?) {
        guard let index = publicMirrorSession?.disconnects?.firstIndex(where: { $0.id == id }) else { return }
        publicMirrorSession!.disconnects![index].state = state
        publicMirrorSession!.disconnects![index].failure = failure
        if state == .needsAttention {
            self.state = .needsAttention
            self.failure = failure
        }
    }
}
