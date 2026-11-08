import Foundation
import CoreGraphics
import OSLog

private let showSettleLogger = Logger(subsystem: "com.brettinternet.displaypanel", category: "display-hide")

/// Public mirroring only. A successful mirror is NOT a signal disconnect and
/// does not qualify firmware input switching or private display recovery.
public enum DisplayMirroring {
    public static func mirror(selector: String, source: String, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController.production.mirror(selector: selector, source: source, store: store)
        print("Hidden by mirroring. Journal: \(store.url.path) (\(journal.id))")
        print("Resolution, HDR, refresh rate, windows and Spaces may change; brightness and monitor input don't.")
    }

    public static func unmirror(selector: String? = nil, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController.production.unmirror(store: store, selector: selector)
        let remaining = journal.publicMirrorSession?.removals.filter { !$0.state.resolved }.count ?? 0
        if remaining > 0 {
            print("Shown and verified; \(remaining) more still hidden. Positions may shift slightly until the last one is shown. Journal: \(store.url.path)")
        } else {
            print("Shown; arrangement, modes and main display restored and verified. Journal: \(store.url.path)")
        }
    }

    static func verifyRemoval(selector: String?, journalPath: String?) throws {
        let store = store(journalPath)
        let journal = try MirrorController.production.verifyRemoval(store: store, selector: selector)
        print("Hidden state verified. Journal: \(store.url.path) (\(journal.id))")
    }

    private static func store(_ path: String?) -> RecoveryStore {
        RecoveryStore(url: path.map { URL(fileURLWithPath: $0) } ?? RecoveryStore.defaultURL)
    }
}

/// Same closure-injected transaction seam as the recovery backend, without
/// resolving or invoking any private setter. Completion consumes even on error.
struct MirrorTransaction {
    var begin: () throws -> CGDisplayConfigRef = {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "begin mirror")
        guard let config else { throw RecoveryError.unsafe("missing mirror transaction") }
        return config
    }
    var stage: (CGDisplayConfigRef, UInt32, UInt32) throws -> Void = {
        try check(CGConfigureDisplayMirrorOfDisplay($0, $1, $2), "stage mirror")
    }
    var complete: (CGDisplayConfigRef, CGConfigureOption) throws -> Void = {
        try check(CGCompleteDisplayConfiguration($0, $1), "commit mirror")
    }
    var cancel: (CGDisplayConfigRef) -> Void = { _ = CGCancelDisplayConfiguration($0) }

    var stageOrigin: (CGDisplayConfigRef, UInt32, Int32, Int32) throws -> Void = {
        try check(CGConfigureDisplayOrigin($0, $1, $2, $3), "stage wake origin")
    }

    func apply(removals: [(UInt32, UInt32)], origins: [(UInt32, Int32, Int32)],
               revalidate: () throws -> Void) throws {
        try revalidate()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try revalidate()
        for (target, source) in removals {
            try revalidate()
            try stage(config, target, source)
        }
        for (id, x, y) in origins {
            try revalidate()
            try stageOrigin(config, id, x, y)
        }
        try revalidate()
        consumed = true
        try complete(config, .forSession)
    }

    private static func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else {
            throw RecoveryError.unsafe("\(operation) failed (CGError \(error.rawValue))")
        }
    }
}

enum HiddenMirrorTopology {
    static func verify(snapshot: RecoverySnapshot, targetID: UInt32, sourceID: UInt32,
                       current: RecoverySnapshot) throws {
        try snapshot.validateRestoration(to: current)
        guard let target = snapshot.displays.first(where: { $0.id == targetID }),
              let source = snapshot.displays.first(where: { $0.id == sourceID }),
              target.id != source.id,
              current.displays.filter(\.main).count == 1 else {
            throw RecoveryError.unsafe("mirror topology verification mismatch")
        }
        let originalByID = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.id, $0) })
        for display in current.displays {
            guard let original = originalByID[display.id] else {
                throw RecoveryError.unsafe("mirror topology verification mismatch")
            }
            let expectedMirror = display.id == targetID ? source.uuid : nil
            let mirrorMatches: Bool
            if let expectedMirror, let observedMirror = display.mirrorUUID {
                mirrorMatches = expectedMirror.caseInsensitiveCompare(observedMirror) == .orderedSame
            } else {
                mirrorMatches = expectedMirror == nil && display.mirrorUUID == nil
            }
            guard mirrorMatches,
                  (target.main || display.main == original.main),
                  (display.id != sourceID || display.active) else {
                throw RecoveryError.unsafe("mirror topology verification mismatch")
            }
        }
    }

    static func matches(snapshot: RecoverySnapshot, targetID: UInt32, sourceID: UInt32,
                        current: RecoverySnapshot) -> Bool {
        (try? verify(snapshot: snapshot, targetID: targetID, sourceID: sourceID, current: current)) != nil
    }
}

enum MirrorSessionTopology {
    static func activeRemovals(_ removals: [PublicMirrorRemoval]) -> [PublicMirrorRemoval] {
        removals.filter { !$0.state.resolved }
    }

    /// Hiding a display that other removals mirror onto moves them onto its
    /// source. They keep the old source until the move verifies, so an
    /// interrupted Hide matches either the old or the moved topology.
    static func moving(_ removals: [PublicMirrorRemoval], onto mover: PublicMirrorRemoval) -> [PublicMirrorRemoval] {
        removals.map { removal in
            guard !removal.state.resolved, removal.id != mover.id,
                  removal.sourceUUID == mover.targetUUID else { return removal }
            var moved = removal
            moved.sourceUUID = mover.sourceUUID
            moved.sourceID = mover.sourceID
            moved.movedBy = mover.id
            return moved
        }
    }

    /// `turnedOff` displays are Turn off targets. Absent ones are left out of
    /// `baseline` (see PublicMirrorSession.visible); like removals, they free
    /// positions and the main role from the exact baseline.
    static func matches(_ session: PublicMirrorSession, current: RecoverySnapshot,
                        repairingTarget: String? = nil) -> Bool {
        let view = session.visible(in: current)
        return matches(baseline: view.baseline, removals: view.removals, current: current,
                       repairingTarget: repairingTarget, turnedOff: session.turnedOff)
    }

    static func matches(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                        current: RecoverySnapshot, repairingTarget: String? = nil,
                        turnedOff: Set<String> = []) -> Bool {
        guard (try? baseline.validateRestoration(to: current)) != nil,
              current.displays.filter(\.main).count == 1 else { return false }
        if activeRemovals(removals).isEmpty && turnedOff.isEmpty {
            return (try? baseline.verify(current)) != nil
        }
        var activeByTarget: [String: PublicMirrorRemoval] = [:]
        for removal in activeRemovals(removals) {
            guard activeByTarget[removal.targetUUID] == nil,
                  pendingShowSurvivorsMatch(removal, baseline: baseline, current: current) else { return false }
            activeByTarget[removal.targetUUID] = removal
        }
        for original in baseline.displays {
            guard let observed = current.displays.first(where: { $0.uuid == original.uuid }) else { return false }
            if let removal = activeByTarget[original.uuid] {
                guard observed.mirrorUUID?.caseInsensitiveCompare(removal.sourceUUID) == .orderedSame,
                      !observed.active,
                      let source = current.displays.first(where: { $0.uuid == removal.sourceUUID }),
                      source.id == removal.sourceID, source.active, source.mirrorUUID == nil else { return false }
            } else {
                // Positions are not session invariants while any display is
                // removed: macOS may rearrange on mirror and place a partially
                // shown target near its saved origin. The final Show verifies
                // the whole baseline exactly.
                guard observed.mirrorUUID == original.mirrorUUID else { return false }
                if original.active, !observed.active { return false }
            }
        }
        // Removing a non-main display never moves main. Only while the
        // original main display is removed, or its repair returns it to (0,0),
        // may macOS report another as main.
        if let originalMain = baseline.displays.first(where: \.main), activeByTarget[originalMain.uuid] == nil,
           originalMain.uuid != repairingTarget, !turnedOff.contains(originalMain.uuid),
           current.displays.first(where: \.main)?.uuid != originalMain.uuid {
            return false
        }
        return true
    }

    /// Postcondition of a wake resume: matches() plus the exact visible main,
    /// origins relative to it, and modes. Mirror-only matches() is weaker and
    /// must not clear a failed wake transaction.
    /// With the saved main turned off, macOS picks the visible main, so only
    /// modes compare. Other turned-off displays keep wherever they are.
    static func matchesWakeLayout(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                  current: RecoverySnapshot, turnedOff: Set<String> = []) -> Bool {
        let active = activeRemovals(removals)
        let targets = Set(active.map(\.targetUUID))
        let visible = baseline.displays.filter { !targets.contains($0.uuid) && !turnedOff.contains($0.uuid) && $0.active }
        guard matches(baseline: baseline, removals: removals, current: current, turnedOff: turnedOff) else { return false }
        guard let savedMain = baseline.displays.first(where: \.main), !turnedOff.contains(savedMain.uuid) else {
            return visible.allSatisfy { saved in current.displays.contains { $0.id == saved.id && $0.mode == saved.mode } }
        }
        guard let mainUUID = targets.contains(savedMain.uuid)
                ? active.first(where: { $0.targetUUID == savedMain.uuid })?.sourceUUID : savedMain.uuid,
              let main = baseline.displays.first(where: { $0.uuid == mainUUID }),
              current.displays.first(where: \.main)?.uuid == mainUUID else { return false }
        return visible.allSatisfy { saved in
            current.displays.contains {
                $0.id == saved.id && $0.mode == saved.mode &&
                    Int64($0.x) == Int64(saved.x) - Int64(main.x) && Int64($0.y) == Int64(saved.y) - Int64(main.y)
            }
        }
    }

    /// Postcondition of a Show that leaves other displays removed. With other
    /// displays still mirrored, the saved origin may not be a layout macOS
    /// accepts (recorded on 26A434: requested (3440,-4), placed at (3440,0)),
    /// so the target's origin is requested but not required. Everything else
    /// is exact: identity, the target's mode and main role, other visible
    /// displays (see showSurvivorsUnchanged) and every remaining removal.
    /// When no removal remains, matches() requires the whole baseline.
    static func verifyPartialShow(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval], removalID: UUID,
                                  before: RecoverySnapshot, current: RecoverySnapshot,
                                  turnedOff: Set<String> = []) throws {
        try baseline.validateRestoration(to: current)
        guard let index = removals.firstIndex(where: { $0.id == removalID }) else {
            throw RecoveryError.unsafe("selected removal entry disappeared")
        }
        let targetUUID = removals[index].targetUUID
        guard let original = baseline.displays.first(where: { $0.uuid == targetUUID }),
              let observed = current.displays.first(where: { $0.uuid == targetUUID }),
              observed.mirrorUUID == nil, observed.active,
              observed.mode == original.mode, observed.main == original.main else {
            throw RecoveryError.unsafe("Show did not return the display separately with its saved mode and main-display role; keep recovery")
        }
        guard showSurvivorsUnchanged(baseline: baseline, targetUUID: targetUUID, before: before, current: current) else {
            throw RecoveryError.unsafe("Show changed another visible display; keep recovery")
        }
        var proposed = removals
        proposed[index].state = .restored
        guard matches(baseline: baseline, removals: proposed, current: current, turnedOff: turnedOff) else {
            throw RecoveryError.unsafe("Show changed another removal or did not restore the original layout; keep recovery")
        }
    }

    /// Every display that was visible before the Show stays visible with its
    /// exact mode. Positions are global coordinates relative to the main
    /// display's (0,0), so they compare exactly whenever the main display is
    /// unchanged. A returning original main takes (0,0), and macOS may move
    /// main while other displays are removed; then positions do not compare.
    static func showSurvivorsUnchanged(baseline: RecoverySnapshot, targetUUID: String,
                                       before: RecoverySnapshot, current: RecoverySnapshot) -> Bool {
        guard (try? before.validateRestoration(to: current)) != nil,
              let target = baseline.displays.first(where: { $0.uuid == targetUUID }) else { return false }
        let sameFrame = !target.main &&
            before.displays.first(where: \.main)?.uuid == current.displays.first(where: \.main)?.uuid
        return before.displays.allSatisfy { survivor in
            guard survivor.uuid != targetUUID, survivor.active, survivor.mirrorUUID == nil else { return true }
            guard let observed = current.displays.first(where: { $0.uuid == survivor.uuid }),
                  observed.active, observed.mirrorUUID == nil, observed.mode == survivor.mode else { return false }
            return !sameFrame || (observed.main == survivor.main && observed.x == survivor.x && observed.y == survivor.y)
        }
    }

    /// A pending Show's durable pre-Show snapshot keeps its survivor
    /// expectations across failure, crash and relaunch.
    static func pendingShowSurvivorsMatch(_ removal: PublicMirrorRemoval, baseline: RecoverySnapshot,
                                          current: RecoverySnapshot) -> Bool {
        guard let before = removal.restoreFrom else { return true }
        return showSurvivorsUnchanged(baseline: baseline, targetUUID: removal.targetUUID, before: before, current: current)
    }

    /// Saved modes a Show needs. A target still mirrored by another removal
    /// keeps its follower mode until its own Show; its monitor may be on another
    /// computer's input, offering fewer modes (for example 60 Hz, not 240 Hz).
    static func showModeBaseline(_ baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                 showing targetUUID: String?, current: RecoverySnapshot) -> RecoverySnapshot {
        let followers = Set(activeRemovals(removals).filter { removal in
            removal.targetUUID != targetUUID && current.displays.contains {
                $0.uuid == removal.targetUUID && !$0.active &&
                    $0.mirrorUUID?.caseInsensitiveCompare(removal.sourceUUID) == .orderedSame
            }
        }.map(\.targetUUID))
        return baseline.excluding(followers)
    }

    /// The final *physical* Show restores the full baseline even if a previous
    /// Show cleared its mirror but retained unresolved layout recovery. Every
    /// other display must already be separate; never replay a sibling mirror.
    static func canRestoreFinalLayout(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                      targetUUID: String, current: RecoverySnapshot) -> Bool {
        canRestoreFinalLayout(baseline: baseline, showing: activeRemovals(removals).filter { $0.targetUUID == targetUUID },
                              current: current)
    }

    /// Each shown removal may still mirror its own source (Show together).
    static func canRestoreFinalLayout(baseline: RecoverySnapshot, showing: [PublicMirrorRemoval],
                                      current: RecoverySnapshot) -> Bool {
        guard !showing.isEmpty, (try? baseline.validateRestoration(to: current)) != nil,
              current.displays.filter(\.main).count == 1 else { return false }
        return current.displays.allSatisfy { display in
            if let selected = showing.first(where: { $0.targetUUID == display.uuid }), let source = display.mirrorUUID {
                return source.caseInsensitiveCompare(selected.sourceUUID) == .orderedSame && !display.active
            }
            return display.mirrorUUID == nil &&
                (display.active || baseline.displays.first(where: { $0.uuid == display.uuid })?.active == false)
        }
    }

    /// A partial Show can clear its mirror yet fail its postcondition (for
    /// example its mode or main role). Only that recorded failed target may be repaired;
    /// survivors and sibling topology must still verify before another write.
    static func canRepairTargetLayout(baseline: RecoverySnapshot, removals: [PublicMirrorRemoval],
                                      targetUUID: String, current: RecoverySnapshot,
                                      turnedOff: Set<String> = []) -> Bool {
        guard activeRemovals(removals).count + turnedOff.count > 1,
              let index = removals.firstIndex(where: { $0.targetUUID == targetUUID && !$0.state.resolved }),
              removals[index].state == .needsAttention || removals[index].state == .restoring,
              pendingShowSurvivorsMatch(removals[index], baseline: baseline, current: current),
              let target = current.displays.first(where: { $0.uuid == targetUUID }),
              target.mirrorUUID == nil, target.active else { return false }
        var siblings = removals
        siblings[index].state = .cancelled
        return matches(baseline: baseline, removals: siblings, current: current, repairingTarget: targetUUID,
                       turnedOff: turnedOff)
    }

    static func targetMatchesBaseline(_ targetUUID: String, baseline: RecoverySnapshot,
                                      current: RecoverySnapshot) -> Bool {
        guard (try? baseline.validateRestoration(to: current)) != nil,
              let original = baseline.displays.first(where: { $0.uuid == targetUUID }),
              let observed = current.displays.first(where: { $0.uuid == targetUUID }) else { return false }
        return observed.mirrorUUID == nil && observed.active == original.active &&
            observed.main == original.main && observed.x == original.x && observed.y == original.y &&
            observed.mode == original.mode
    }

    static func matchesBeforeOperation(_ removal: PublicMirrorRemoval,
                                       current: RecoverySnapshot) -> Bool {
        (try? removal.beforeOperation.verify(current)) != nil
    }
}

enum MirrorRecoveryGuidance {
    static let manualSteps = "Manual recovery: keep the journal; in System Settings → Displays, turn off mirroring and drag the menu bar back to the original display. After correcting the layout, inspect recovery status and run recovery verify."
}

struct MirrorController {
    var records: () throws -> [DisplayRecord] = { DisplayInventory.records() }
    var operationLock: () -> RecoveryStore = { RecoveryStore.operationLock() }
    var engine = RecoveryEngine.publicMirror
    var preflightModes: (RecoverySnapshot) throws -> Void = { _ = try RecoveryConfiguration.resolveModes($0) }
    var availableModes: (UInt32) -> [RecoveryMode] = { DisplayModeProtectionController.modes($0).map(RecoveryMode.init) }
    var transaction = MirrorTransaction()
    var restoreTarget: (RecoverySnapshot, String, () throws -> Void, () throws -> RecoverySnapshot) throws -> Void = {
        try RecoveryConfiguration.restoreTarget($0, targetUUID: $1, revalidate: $2, capture: $3)
    }
    /// Nil keeps Turn off unavailable, so tests never reach the private setter.
    var turnOffBackend: DisplayTurnOffBackend?

    func mirror(selector: String, source: String, store: RecoveryStore,
                expectedTarget: DisplayHideIdentity? = nil,
                expectedSource: DisplayHideIdentity? = nil,
                wakeExpectation: DisplayHideWakeExpectation? = nil,
                beforeMirror: (RecoveryDisplay) throws -> Void = { _ in }) throws -> RecoveryJournal {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }

        if let wakeExpectation, !wakeExpectation.resumeRemovalIDs.isEmpty {
            guard expectedTarget == wakeExpectation.target, expectedSource == wakeExpectation.source else {
                throw RecoveryError.unsafe("wake resume selection changed")
            }
            return try resumeWakeSession(wakeExpectation, store: store)
        }

        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
              let target = DisplaySelector.resolve(selector, in: available),
              let sourceRecord = DisplaySelector.resolve(source, in: available), target.id != sourceRecord.id,
              target.online, target.active, !target.asleep, !target.builtin,
              sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
            throw RecoveryError.unsafe("mirror requires one stable-identity external active target (built-in displays are refused) and a distinct active source; missing/ambiguous selectors refused; use dp list")
        }
        if let expectedTarget, !matches(expectedTarget, record: target) {
            throw RecoveryError.unsafe("target identity changed after confirmation; refresh Displays and confirm Hide again")
        }
        if let expectedSource, !matches(expectedSource, record: sourceRecord) {
            throw RecoveryError.unsafe("mirror source identity changed after confirmation; refresh Displays and confirm Hide again")
        }

        let current = try engine.capture()
        guard Set(current.displays.map(\.id)) == Set(available.filter(\.online).map(\.id)) else {
            throw RecoveryError.unsafe("display set changed during capture; refusing mirror")
        }
        var existing = try store.exists() ? store.load() : nil
        if var unresolved = existing, !unresolved.state.resolved {
            try adoptRenumbering(&unresolved, current: current, store: store)
            existing = unresolved
        }
        if let wakeExpectation {
            guard let existing else {
                throw RecoveryError.unsafe("wake resume journal disappeared; inspect recovery before continuing")
            }
            try validateWakeResumeExpectation(
                wakeExpectation, journal: existing, current: current,
                target: target, source: sourceRecord,
                expectedTarget: expectedTarget, expectedSource: expectedSource
            )
        }
        var journal: RecoveryJournal
        var session: PublicMirrorSession
        let baseline: RecoverySnapshot
        if let existing, !existing.state.resolved {
            if let previous = existing.publicMirrorSession {
                // macOS can drop Hide mirrors when a display turns off (26B123).
                guard previous.unresolvedDisconnects.isEmpty else {
                    throw RecoveryError.unsafe("a display is turned off; Show it before mirroring another")
                }
                guard previous.removals.allSatisfy({ $0.state != .needsAttention && $0.state != .captured && $0.state != .restoring }),
                      MirrorSessionTopology.matches(previous, current: current) else {
                    throw RecoveryError.unsafe("display recovery needs attention; resolve it before starting another removal")
                }
                journal = existing
                session = previous
                baseline = previous.visible(in: current).baseline
            } else if existing.mirrorTargetID != nil, existing.mirrorSourceID != nil,
                      existing.state == .mirrored, existing.disabledByUsID == nil,
                      let targetSaved = existing.snapshot.displays.first(where: { $0.id == existing.mirrorTargetID }),
                      let sourceSaved = existing.snapshot.displays.first(where: { $0.id == existing.mirrorSourceID }),
                      HiddenMirrorTopology.matches(snapshot: existing.snapshot, targetID: targetSaved.id,
                                                   sourceID: sourceSaved.id, current: current) {
                // Upgrade a healthy singleton public journal atomically. Its
                // original snapshot becomes the immutable session baseline.
                let removal = PublicMirrorRemoval(target: targetSaved, source: sourceSaved,
                                                  beforeOperation: existing.snapshot, state: .mirrored)
                let upgraded = PublicMirrorSession(baseline: existing.snapshot, removals: [removal])
                journal = existing
                journal.version = 3
                journal.publicMirrorSession = upgraded
                session = upgraded
                baseline = existing.snapshot
                try journal.validate()
                try store.save(journal)
            } else {
                throw RecoveryError.unsafe("unresolved journal; verify or recover it before starting a removal")
            }
        } else {
            baseline = current
            guard current.displays.allSatisfy({ $0.mirrorUUID == nil }) else {
                throw RecoveryError.unsafe("existing mirrors are present; refusing to start a public-mirror session")
            }
            session = PublicMirrorSession(baseline: baseline, removals: [])
            journal = RecoveryJournal(snapshot: baseline)
        }

        guard baseline.displays.contains(where: { $0.uuid == (target.uuid ?? "").lowercased() }),
              let targetSaved = baseline.displays.first(where: { $0.id == target.id }),
              let sourceSaved = baseline.displays.first(where: { $0.id == sourceRecord.id }),
              targetSaved.uuid.caseInsensitiveCompare(target.uuid ?? "") == .orderedSame,
              sourceSaved.uuid.caseInsensitiveCompare(sourceRecord.uuid ?? "") == .orderedSame,
              targetSaved.vendor == target.vendor, targetSaved.model == target.model, targetSaved.serial == target.serial,
              sourceSaved.vendor == sourceRecord.vendor, sourceSaved.model == sourceRecord.model, sourceSaved.serial == sourceRecord.serial,
              targetSaved.active, sourceSaved.active else {
            throw RecoveryError.unsafe("selection changed during capture; select again")
        }
        let activeRemovals = session.removals.filter { !$0.state.resolved }
        guard !activeRemovals.contains(where: { $0.targetUUID == targetSaved.uuid }),
              !session.turnedOff.contains(targetSaved.uuid) else {
            throw RecoveryError.unsafe("this display is already hidden")
        }
        guard !session.turnedOff.contains(sourceSaved.uuid) else {
            throw RecoveryError.unsafe("cannot mirror onto a turned-off display; Show it first")
        }
        guard !activeRemovals.contains(where: { $0.targetUUID == sourceSaved.uuid }) else {
            throw RecoveryError.unsafe("cannot remove a display that another removal mirrors onto")
        }
        guard sourceSaved.uuid != targetSaved.uuid,
              let currentTarget = current.displays.first(where: { $0.id == target.id }),
              let currentSource = current.displays.first(where: { $0.id == sourceRecord.id }),
              currentTarget.mirrorUUID == nil, currentTarget.active,
              currentSource.mirrorUUID == nil, currentSource.active else {
            throw RecoveryError.unsafe("target and source must be separate active displays; removed or externally mirrored displays are refused")
        }
        let visibleAfterHide = current.displays.filter {
            $0.active && $0.mirrorUUID == nil && $0.id != target.id
        }
        guard !visibleAfterHide.isEmpty else {
            throw RecoveryError.unsafe("refusing to hide the last visible display")
        }
        guard MirrorSessionTopology.matches(session, current: current) else {
            throw RecoveryError.unsafe("current topology does not match the existing removal session")
        }
        try baseline.validateRestoration(to: current)
        try current.verify(engine.capture())
        // A hidden monitor on another input often offers fewer modes; Show
        // returns its input before checking them, so only visible displays block.
        try preflightModes(MirrorSessionTopology.showModeBaseline(baseline, removals: session.removals,
                                                                  showing: nil, current: current))

        let removal = PublicMirrorRemoval(target: targetSaved, source: sourceSaved, beforeOperation: current)
        // Removals mirroring onto the target move with it, staged first so the
        // target is no longer a mirror source when it joins the source's set.
        let followers = activeRemovals.filter { $0.sourceUUID == targetSaved.uuid }
        let pairs = followers.map { ($0.targetID, sourceRecord.id) } + [(target.id, sourceRecord.id)]
        session.removals.append(removal)
        journal.version = 3
        journal.publicMirrorSession = session
        journal.mirrorTargetID = session.removals.count == 1 ? target.id : nil
        journal.mirrorSourceID = session.removals.count == 1 ? sourceRecord.id : nil
        journal.state = .captured
        journal.trigger = "mirror"
        journal.failure = nil
        if existing == nil || existing?.state.resolved == true {
            try store.create(journal)
        } else {
            try store.save(journal)
        }

        do {
            // Durable per-display intent precedes both input switching and
            // topology changes. A second Hide cannot replace healthy entries.
            try beforeMirror(targetSaved)
            try transaction.apply(removals: pairs, origins: []) {
                try current.verify(engine.capture())
                if let wakeExpectation, let existing {
                    try validateWakeResumeWriteBoundary(
                        wakeExpectation, originalJournal: existing, pendingJournal: journal,
                        pendingRemoval: removal, current: current, store: store
                    )
                }
            }
            let mainBefore = current.displays.first(where: \.main)?.uuid
            try engine.converge {
                let observedTopology = try engine.capture()
                guard var observed = journal.publicMirrorSession else {
                    throw RecoveryError.unsafe("mirror session verification mismatch")
                }
                observed.removals = MirrorSessionTopology.moving(observed.removals, onto: removal)
                guard MirrorSessionTopology.matches(observed, current: observedTopology),
                      currentTarget.main || observedTopology.displays.first(where: \.main)?.uuid == mainBefore else {
                    throw RecoveryError.unsafe("mirror session verification mismatch")
                }
            }
            guard var savedSession = journal.publicMirrorSession,
                  let index = savedSession.removals.firstIndex(where: { $0.id == removal.id }) else {
                throw RecoveryError.unsafe("durable removal entry disappeared")
            }
            savedSession.removals = MirrorSessionTopology.moving(savedSession.removals, onto: removal)
            savedSession.removals[index].state = .mirrored
            savedSession.removals[index].failure = nil
            journal.publicMirrorSession = savedSession
            journal.state = .mirrored
            try store.save(journal)
            return journal
        } catch {
            if var savedSession = journal.publicMirrorSession,
               let index = savedSession.removals.firstIndex(where: { $0.id == removal.id }) {
                savedSession.removals[index].state = .needsAttention
                savedSession.removals[index].failure = String(describing: error)
                journal.publicMirrorSession = savedSession
            }
            journal.state = .needsAttention
            journal.failure = String(describing: error)
            try? store.save(journal)
            throw fallback(error, store: store, selector: target.uuid)
        }
    }

    /// Reapply only the live app's pre-sleep removal set. Follower modes are
    /// negotiated by mirroring, not restored; keep their exact saved modes for Show.
    private func resumeWakeSession(_ expectation: DisplayHideWakeExpectation,
                                   store: RecoveryStore) throws -> RecoveryJournal {
        var journal = try store.load()
        let before = try engine.capture()
        guard journal.id.uuidString.caseInsensitiveCompare(expectation.journalID) == .orderedSame,
              journal.wakeResumeIdentity() == expectation.journalIdentity,
              before.stableTopologyIdentity() == expectation.observedTopologyIdentity,
              var session = journal.publicMirrorSession,
              journal.wakeBaselineIdentity() == expectation.baselineIdentity,
              journal.disabledByUsID == nil, !journal.state.resolved,
              session.unresolvedDisconnects.allSatisfy({ $0.state == .off }) else {
            throw RecoveryError.unsafe("wake resume journal, baseline or topology changed")
        }
        // A turned-off display keeps whatever macOS did with it; never turn it off again.
        let turnedOff = session.turnedOff
        let baseline = session.visible(in: before).baseline
        let ids = Set(expectation.resumeRemovalIDs.map { $0.lowercased() })
        let removals = session.removals.filter { ids.contains($0.id.uuidString.lowercased()) }
        guard ids.count == expectation.resumeRemovalIDs.count, removals.count == ids.count,
              Set(session.removals.filter { !$0.state.resolved }.map { $0.id.uuidString.lowercased() }) == ids,
              removals.allSatisfy({ ($0.state == .mirrored || $0.state == .needsAttention) && $0.restoreFrom == nil }),
              removals.contains(where: {
                  $0.targetID == expectation.target.displayID && $0.targetUUID == expectation.target.uuid &&
                  $0.sourceID == expectation.source.displayID && $0.sourceUUID == expectation.source.uuid
              }) else {
            throw RecoveryError.unsafe("wake resume removal intent changed or a Show was interrupted")
        }
        try baseline.validateRestoration(to: before)
        let targets = Set(removals.map(\.targetUUID))
        let savedMain = session.baseline.displays.first(where: \.main)
        // With the saved main turned off, macOS chose the visible main: stage mirrors only.
        let mainTurnedOff = savedMain.map { turnedOff.contains($0.uuid) } ?? false
        let mainUUID = savedMain.flatMap { savedMain in
            targets.contains(savedMain.uuid)
                ? removals.first(where: { $0.targetUUID == savedMain.uuid })?.sourceUUID : savedMain.uuid
        }
        let main = baseline.displays.first(where: { $0.uuid == mainUUID })
        guard targets.count == removals.count,
              removals.allSatisfy({ !targets.contains($0.sourceUUID) }),
              mainTurnedOff || main != nil,
              before.displays.filter(\.main).count == 1 else {
            throw RecoveryError.unsafe("wake resume has no unambiguous visible main display")
        }
        // Accept lost/intact owned mirrors, not external mirrors or a mode
        // change on an unrelated visible desktop.
        for display in before.displays where !turnedOff.contains(display.uuid) {
            let saved = baseline.displays.first { $0.uuid == display.uuid }!
            if let removal = removals.first(where: { $0.targetUUID == display.uuid }) {
                guard !display.builtin,
                      (display.active && display.mirrorUUID == nil) ||
                        (!display.active && display.mirrorUUID == removal.sourceUUID) else {
                    throw RecoveryError.unsafe("wake resume target is unavailable or has an unrelated mirror")
                }
            } else {
                guard display.active == saved.active, display.mirrorUUID == saved.mirrorUUID,
                      display.mode == saved.mode else {
                    throw RecoveryError.unsafe("wake resume changed an unrelated desktop or its mode")
                }
            }
        }
        let origins = try (mainTurnedOff ? [] : baseline.displays)
            .filter { !targets.contains($0.uuid) && !turnedOff.contains($0.uuid) && $0.active }
            .sorted { $0.uuid != mainUUID && $1.uuid == mainUUID }
            .map { display -> (UInt32, Int32, Int32) in
                guard let main, let x = Int32(exactly: Int64(display.x) - Int64(main.x)),
                      let y = Int32(exactly: Int64(display.y) - Int64(main.y)) else {
                    throw RecoveryError.unsafe("wake resume origin is unrepresentable")
                }
                return (display.id, x, y)
            }
        func validateAwake() throws {
            let available = try records()
            guard Set(available.map(\.id)).count == available.count,
                  Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count,
                  Set(available.filter(\.online).map(\.id)) == Set(before.displays.map(\.id)),
                  available.contains(where: { matches(expectation.target, record: $0) }),
                  available.contains(where: { matches(expectation.source, record: $0) }),
                  before.displays.allSatisfy({ saved in
                      available.contains { record in
                          record.id == saved.id && record.uuid?.lowercased() == saved.uuid &&
                          record.vendor == saved.vendor && record.model == saved.model && record.serial == saved.serial &&
                          record.online && !record.asleep && record.active == saved.active
                      }
                  }) else {
                throw RecoveryError.unsafe("wake resume displays are not awake with the captured identities")
            }
        }
        try validateAwake()
        // A repeated/own-write notification is not another write. Mirror-only
        // verification is insufficient here: visible origins/main must match too.
        func matchesWakeLayout(_ current: RecoverySnapshot) -> Bool {
            let view = session.visible(in: current)
            return MirrorSessionTopology.matchesWakeLayout(baseline: view.baseline, removals: view.removals,
                                                           current: current, turnedOff: turnedOff)
        }
        if journal.state == .mirrored, matchesWakeLayout(before) {
            return journal
        }
        // Keep the original journal/baseline/removal IDs. Intent is durable
        // before staging, and a failed/consumed transaction is never retried.
        for index in session.removals.indices where ids.contains(session.removals[index].id.uuidString.lowercased()) {
            session.removals[index].state = .captured
            session.removals[index].failure = nil
        }
        journal.publicMirrorSession = session
        journal.state = .captured
        journal.trigger = "wake-resume"
        journal.failure = nil
        try store.save(journal)
        let pending = journal
        do {
            try transaction.apply(removals: removals.map { ($0.targetID, $0.sourceID) }, origins: origins) {
                try before.verify(engine.capture())
                try validateAwake()
                guard Self.sameStoredJournal(pending, try store.load()) else {
                    throw RecoveryError.unsafe("wake resume journal changed at the writer boundary")
                }
            }
            try engine.converge {
                guard matchesWakeLayout(try engine.capture()) else {
                    throw RecoveryError.unsafe("wake resume mirrors or visible layout did not verify")
                }
            }
            guard Self.sameStoredJournal(pending, try store.load()) else {
                throw RecoveryError.unsafe("wake resume journal changed during verification")
            }
            for index in session.removals.indices where ids.contains(session.removals[index].id.uuidString.lowercased()) {
                session.removals[index].state = .mirrored
            }
            journal.publicMirrorSession = session
            journal.state = .mirrored
            try store.save(journal)
            return journal
        } catch {
            if let durable = try? store.load(), Self.sameStoredJournal(pending, durable) {
                for index in session.removals.indices where ids.contains(session.removals[index].id.uuidString.lowercased()) {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = error.localizedDescription
                }
                journal.publicMirrorSession = session
                journal.state = .needsAttention
                journal.failure = error.localizedDescription
                try? store.save(journal)
            }
            throw error
        }
    }

    private func validateWakeResumeExpectation(
        _ expectation: DisplayHideWakeExpectation,
        journal: RecoveryJournal,
        current: RecoverySnapshot,
        target: DisplayRecord,
        source: DisplayRecord,
        expectedTarget: DisplayHideIdentity?,
        expectedSource: DisplayHideIdentity?
    ) throws {
        guard journal.id.uuidString.caseInsensitiveCompare(expectation.journalID) == .orderedSame,
              journal.wakeResumeIdentity() == expectation.journalIdentity,
              journal.wakeBaselineIdentity() == expectation.baselineIdentity,
              current.stableTopologyIdentity() == expectation.observedTopologyIdentity,
              expectedTarget == expectation.target, expectedSource == expectation.source,
              matches(expectation.target, record: target), matches(expectation.source, record: source) else {
            throw RecoveryError.unsafe("wake resume journal, session, baseline, topology, or target/source identity changed; no mirror was staged")
        }
        var baseline = journal.publicMirrorSession?.visible(in: current).baseline ?? journal.snapshot
        if journal.state.resolved {
            // Unresolved journals were adopted by the caller; a restored one is
            // only compared, so translate a same-boot renumbering here.
            baseline = try baseline.renumbered(to: current).remoded(available: availableModes)
        }
        try baseline.validateRestoration(to: current)
        if journal.state.resolved {
            try baseline.verify(current)
        } else if let session = journal.publicMirrorSession {
            guard MirrorSessionTopology.matches(session, current: current) else {
                throw RecoveryError.unsafe("wake resume session topology changed; no mirror was staged")
            }
        } else {
            guard let targetID = journal.mirrorTargetID, let sourceID = journal.mirrorSourceID,
                  HiddenMirrorTopology.matches(snapshot: baseline, targetID: targetID, sourceID: sourceID, current: current) else {
                throw RecoveryError.unsafe("wake resume legacy mirror topology changed; no mirror was staged")
            }
        }
    }

    private func validateWakeResumeWriteBoundary(
        _ expectation: DisplayHideWakeExpectation,
        originalJournal: RecoveryJournal,
        pendingJournal: RecoveryJournal,
        pendingRemoval: PublicMirrorRemoval,
        current: RecoverySnapshot,
        store: RecoveryStore
    ) throws {
        guard current.stableTopologyIdentity() == expectation.observedTopologyIdentity,
              let pendingSession = pendingJournal.publicMirrorSession,
              pendingJournal.wakeBaselineIdentity() == expectation.baselineIdentity,
              let last = pendingSession.removals.last, last == pendingRemoval,
              last.state == .captured,
              last.targetUUID == expectation.target.uuid.lowercased(),
              last.targetID == expectation.target.displayID,
              last.sourceUUID == expectation.source.uuid.lowercased(),
              last.sourceID == expectation.source.displayID,
              (try? pendingRemoval.beforeOperation.verify(current)) != nil else {
            throw RecoveryError.unsafe("wake resume transaction no longer matches its captured journal and topology; transaction cancelled")
        }
        let durable = try store.load()
        guard Self.sameStoredJournal(pendingJournal, durable) else {
            throw RecoveryError.unsafe("wake resume journal changed at the writer boundary; transaction cancelled")
        }
        if originalJournal.state.resolved {
            let archiveURL = store.url.deletingLastPathComponent()
                .appendingPathComponent("recovery-\(originalJournal.id.uuidString).json")
            let archived = try RecoveryStore(url: archiveURL).load()
            guard archived.wakeResumeIdentity() == expectation.journalIdentity else {
                throw RecoveryError.unsafe("wake resume source journal changed at the writer boundary; transaction cancelled")
            }
        } else if let originalSession = originalJournal.publicMirrorSession {
            guard Array(pendingSession.removals.dropLast()) == originalSession.removals,
                  pendingSession.baseline.stableTopologyIdentity() == originalSession.baseline.stableTopologyIdentity() else {
                throw RecoveryError.unsafe("wake resume session changed while preparing the transaction; transaction cancelled")
            }
        } else {
            throw RecoveryError.unsafe("wake resume source journal kind changed; transaction cancelled")
        }
    }

    static func sameStoredJournal(_ lhs: RecoveryJournal, _ rhs: RecoveryJournal) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    func unmirror(store: RecoveryStore, selector: String? = nil, expectedID: UUID? = nil,
                  noOpWhenAlreadyResolved: Bool = false,
                  returnInputBeforeRestore: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)? = nil,
                  relinkInput: ((RecoveryDisplay) throws -> Bool)? = nil) throws -> RecoveryJournal {
        do {
            let operation = operationLock()
            try operation.lock()
            defer { operation.unlock() }
            try store.lock()
            defer { store.unlock() }
            var journal = try store.load()
            if let expectedID, journal.id != expectedID {
                throw RecoveryError.unsafe("journal changed since confirmation; inspect recovery status and confirm again")
            }
            if journal.publicMirrorSession != nil {
                return try unmirrorSession(&journal, selector: selector, expectedID: expectedID,
                                          noOpWhenAlreadyResolved: noOpWhenAlreadyResolved,
                                          store: store, returnInputBeforeRestore: returnInputBeforeRestore,
                                          relinkInput: relinkInput)
            }
            guard journal.mirrorTargetID != nil, journal.mirrorSourceID != nil else {
                throw RecoveryError.unsafe("not a mirror journal; inspect recovery status")
            }
            let target = journal.snapshot.displays.first { $0.id == journal.mirrorTargetID }!
            let source = journal.snapshot.displays.first { $0.id == journal.mirrorSourceID }!
            let wasResolved = journal.state.resolved
            let available = try records()
            guard Set(available.map(\.id)).count == available.count,
                  Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count else {
                throw RecoveryError.unsafe("display identities are ambiguous; reconnect the captured displays and inspect recovery status")
            }
            if let selector {
                guard let selected = DisplaySelector.resolve(selector, in: available),
                      selected.id == target.id,
                      selected.uuid?.lowercased() == target.uuid.lowercased() else {
                    throw RecoveryError.unsafe("back target does not match the journaled mirror target; use dp list and recovery status")
                }
            }
            guard let targetRecord = available.first(where: {
                $0.id == target.id && $0.uuid?.caseInsensitiveCompare(target.uuid) == .orderedSame
            }), targetRecord.online, !targetRecord.asleep else {
                throw RecoveryError.unsafe("journaled target is asleep or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
            }
            guard let sourceRecord = available.first(where: {
                $0.id == source.id && $0.uuid?.caseInsensitiveCompare(source.uuid) == .orderedSame
            }), sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
                throw RecoveryError.unsafe("journaled mirror source is asleep, inactive, or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
            }
            if wasResolved && noOpWhenAlreadyResolved { return journal }
            if !wasResolved {
                do {
                    _ = try prepareShow(journal, baseline: journal.snapshot, target: target, source: source,
                                        store: store, returnInputBeforeRestore: returnInputBeforeRestore,
                                        relinkInput: relinkInput)
                } catch {
                    if Self.sameStoredJournal(journal, try store.load()) {
                        journal.state = .needsAttention
                        journal.failure = error.localizedDescription
                        try store.save(journal)
                    }
                    throw error
                }
            }
            // Public-only engine: no private re-enable, helper or gamma path.
            try engine.finish(&journal, store: store, verifyOnly: false, trigger: "unmirror")
            return journal
        } catch {
            throw fallback(error, store: store, selector: selector)
        }
    }

    /// Show together: every removal in the session returns at once. An input
    /// return relinks the monitor's mirror-set siblings too, so each monitor's
    /// input returns in turn and settles before the next, then one write
    /// restores the whole baseline. Any failure before that write leaves the
    /// session mirrored, so Show can be retried.
    func unmirrorAll(store: RecoveryStore, expectedID: UUID,
                     returnInputBeforeRestore: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)? = nil,
                     relinkInput: ((RecoveryDisplay) throws -> Bool)? = nil) throws -> RecoveryJournal {
        do {
            let operation = operationLock()
            try operation.lock()
            defer { operation.unlock() }
            try store.lock()
            defer { store.unlock() }
            var journal = try store.load()
            guard journal.id == expectedID else {
                throw RecoveryError.unsafe("journal changed since confirmation; inspect recovery status and confirm again")
            }
            guard journal.publicMirrorSession != nil else {
                throw RecoveryError.unsafe("Show together needs a display removal session; inspect recovery status")
            }
            if journal.state.resolved { return journal }
            var current = try engine.capture()
            try adoptRenumbering(&journal, current: current, store: store)
            reconcileSession(&journal, current: current, store: store)
            if journal.state.resolved { return journal }
            func restorable() throws -> (PublicMirrorSession, [PublicMirrorRemoval]) {
                guard let session = journal.publicMirrorSession else {
                    throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
                }
                let active = MirrorSessionTopology.activeRemovals(session.removals)
                guard session.turnedOff.isEmpty,
                      MirrorSessionTopology.canRestoreFinalLayout(baseline: session.baseline, showing: active,
                                                                  current: current) else {
                    throw RecoveryError.unsafe("hidden displays aren’t all mirrored as Hide left them; show each display. No layout was changed")
                }
                return (session, active)
            }
            var (session, active) = try restorable()
            var returnedTargets: Set<String> = []
            for removalID in active.map(\.id) {
                guard let removal = session.removals.first(where: { $0.id == removalID }),
                      let target = session.baseline.displays.first(where: { $0.uuid == removal.targetUUID }),
                      let source = session.baseline.displays.first(where: { $0.uuid == removal.sourceUUID }) else {
                    throw RecoveryError.unsafe("captured target or source identity is missing")
                }
                current = try prepareShow(journal, baseline: session.baseline, target: target, source: source,
                                          returnedTargets: returnedTargets, store: store,
                                          returnInputBeforeRestore: returnInputBeforeRestore, relinkInput: relinkInput)
                returnedTargets.insert(removal.targetUUID)
                try adoptRenumbering(&journal, current: current, store: store)
                (session, active) = try restorable()
            }

            for index in session.removals.indices where !session.removals[index].state.resolved {
                session.removals[index].state = .restoring
                session.removals[index].failure = nil
                session.removals[index].restoreFrom = current
            }
            journal.publicMirrorSession = session
            journal.state = .restoring
            journal.trigger = "unmirror-together"
            try store.save(journal)
            do {
                if (try? session.baseline.verify(current)) == nil {
                    try engine.apply(session.baseline)
                }
                try engine.converge { try session.baseline.verify(engine.capture()) }
                for index in session.removals.indices where session.removals[index].state == .restoring {
                    session.removals[index].state = .restored
                    session.removals[index].restoreFrom = nil
                }
                journal.publicMirrorSession = session
                journal.state = .restored
                journal.failure = nil
                try store.save(journal)
                return journal
            } catch {
                for removal in active {
                    markRemovalNeedsAttention(&journal, removalID: removal.id, reason: String(describing: error))
                }
                try? store.save(journal)
                throw RecoveryError.unsafe(RecoveryError.reason(of: error))
            }
        } catch {
            throw fallback(error, store: store)
        }
    }

    private func unmirrorSession(_ journal: inout RecoveryJournal, selector: String?, expectedID: UUID?,
                                 noOpWhenAlreadyResolved: Bool, store: RecoveryStore,
                                 returnInputBeforeRestore: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)?,
                                 relinkInput: ((RecoveryDisplay) throws -> Bool)?) throws -> RecoveryJournal {
        guard var session = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("missing public-mirror session")
        }
        if let expectedID, journal.id != expectedID {
            throw RecoveryError.unsafe("journal changed since confirmation; inspect recovery status and confirm again")
        }
        if journal.state.resolved && noOpWhenAlreadyResolved { return journal }
        let initialCurrent = try engine.capture()
        try adoptRenumbering(&journal, current: initialCurrent, store: store)
        reconcileSession(&journal, current: initialCurrent, store: store)
        guard let reconciled = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
        }
        session = reconciled
        var active = MirrorSessionTopology.activeRemovals(session.removals)
        let turnedOff = session.unresolvedDisconnects
        guard !active.isEmpty || !turnedOff.isEmpty else {
            if journal.state.resolved { return journal }
            throw RecoveryError.unsafe("no unresolved display removal; inspect recovery status")
        }
        let selectedUUID = try selector.map { selector -> String in
            if let requested = UUID(uuidString: selector) { return requested.uuidString.lowercased() }
            if let record = DisplaySelector.resolve(selector, in: try records()), let uuid = record.uuid {
                return uuid.lowercased()
            }
            throw RecoveryError.unsafe("missing or ambiguous removal selector; use its captured UUID from recovery status")
        }
        if let disconnect = turnedOff.first(where: { $0.targetUUID == selectedUUID }) ??
            (selectedUUID == nil && active.isEmpty && turnedOff.count == 1 ? turnedOff.first : nil) {
            return try showTurnedOff(&journal, disconnectID: disconnect.id, store: store)
        }

        let selected: PublicMirrorRemoval
        if let selectedUUID {
            let matches = active.filter { $0.targetUUID == selectedUUID }
            if matches.isEmpty,
               session.removals.contains(where: { $0.targetUUID == selectedUUID && $0.state.resolved }) ||
                (session.disconnects ?? []).contains(where: { $0.targetUUID == selectedUUID && $0.state.resolved }) {
                return journal
            }
            guard matches.count == 1, let match = matches.first else {
                throw RecoveryError.unsafe("selected display is not an unresolved removal in this journal; use dp recovery status")
            }
            selected = match
        } else {
            guard active.count == 1, turnedOff.isEmpty, let only = active.first else {
                throw RecoveryError.unsafe("several displays are removed; specify --display with the target UUID")
            }
            selected = only
        }

        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count else {
            throw RecoveryError.unsafe("display identities are ambiguous; reconnect the captured displays and inspect recovery status")
        }
        guard let targetRecord = available.first(where: {
            $0.id == selected.targetID && $0.uuid?.caseInsensitiveCompare(selected.targetUUID) == .orderedSame
        }), targetRecord.online, !targetRecord.asleep else {
            throw RecoveryError.unsafe("journaled target is asleep or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
        }
        guard let sourceRecord = available.first(where: {
            $0.id == selected.sourceID && $0.uuid?.caseInsensitiveCompare(selected.sourceUUID) == .orderedSame
        }), sourceRecord.online, sourceRecord.active, !sourceRecord.asleep else {
            throw RecoveryError.unsafe("journaled mirror source is asleep, inactive, or unavailable; wake or reconnect the exact display, then inspect recovery status before Show")
        }
        guard let target = session.baseline.displays.first(where: { $0.uuid == selected.targetUUID }),
              let source = session.baseline.displays.first(where: { $0.uuid == selected.sourceUUID }) else {
            throw RecoveryError.unsafe("captured target or source identity is missing")
        }
        let current = try prepareShow(journal, baseline: session.visible(in: initialCurrent).baseline,
                                      target: target, source: source,
                                      store: store, returnInputBeforeRestore: returnInputBeforeRestore,
                                      relinkInput: relinkInput)
        try adoptRenumbering(&journal, current: current, store: store)
        guard let renumbered = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
        }
        session = renumbered
        // A turned-off display keeps the final whole-baseline restore for its own Show.
        let view = session.visible(in: current)
        guard MirrorSessionTopology.matches(session, current: current) ||
                MirrorSessionTopology.canRestoreFinalLayout(baseline: view.baseline, removals: view.removals,
                                                           targetUUID: selected.targetUUID, current: current) ||
                MirrorSessionTopology.canRepairTargetLayout(baseline: view.baseline, removals: view.removals,
                                                           targetUUID: selected.targetUUID, current: current,
                                                           turnedOff: session.turnedOff) else {
            let reason = "current topology does not match the recorded removal session; no other removal was changed"
            markRemovalNeedsAttention(&journal, removalID: selected.id, reason: reason)
            try? store.save(journal)
            throw RecoveryError.unsafe(reason)
        }
        active = MirrorSessionTopology.activeRemovals(session.removals)
        let finalShow = session.turnedOff.isEmpty && (active.count == 1 || MirrorSessionTopology.canRestoreFinalLayout(
            baseline: session.baseline, removals: session.removals, targetUUID: selected.targetUUID, current: current
        ))
        guard var savedSession = journal.publicMirrorSession,
              let index = savedSession.removals.firstIndex(where: { $0.id == selected.id }) else {
            throw RecoveryError.unsafe("selected removal entry disappeared; keep the journal")
        }
        savedSession.removals[index].state = .restoring
        savedSession.removals[index].failure = nil
        savedSession.removals[index].restoreFrom = current
        journal.publicMirrorSession = savedSession
        journal.state = .restoring
        journal.trigger = "unmirror-\(selected.targetUUID)"
        try store.save(journal)

        do {
            if finalShow {
                if (try? session.baseline.verify(current)) == nil {
                    try engine.apply(session.baseline)
                }
                try engine.converge { try session.baseline.verify(engine.capture()) }
                guard var completed = journal.publicMirrorSession else {
                    throw RecoveryError.unsafe("session disappeared during final restore")
                }
                for index in completed.removals.indices {
                    completed.removals[index].state = .restored
                    completed.removals[index].failure = nil
                    completed.removals[index].restoreFrom = nil
                }
                journal.publicMirrorSession = completed
                journal.state = .restored
                journal.failure = nil
            } else {
                let restoringCurrent = current
                try restoreTarget(view.baseline, selected.targetUUID, {
                    try restoringCurrent.verify(engine.capture())
                }, {
                    try engine.capture()
                })
                try engine.converge {
                    let observed = try engine.capture()
                    let saved = (journal.publicMirrorSession ?? session).visible(in: observed)
                    try MirrorSessionTopology.verifyPartialShow(
                        baseline: saved.baseline, removals: saved.removals, removalID: selected.id,
                        before: restoringCurrent, current: observed, turnedOff: session.turnedOff
                    )
                }
                guard var completed = journal.publicMirrorSession,
                      let index = completed.removals.firstIndex(where: { $0.id == selected.id }) else {
                    throw RecoveryError.unsafe("selected removal entry disappeared")
                }
                completed.removals[index].state = .restored
                completed.removals[index].failure = nil
                completed.removals[index].restoreFrom = nil
                journal.publicMirrorSession = completed
                let attention = completed.removals.first(where: { $0.state == .needsAttention }).map(\.failure) ??
                    completed.unresolvedDisconnects.first(where: { $0.state == .needsAttention }).map(\.failure)
                journal.state = attention == nil ? .mirrored : .needsAttention
                journal.failure = attention ?? nil
            }
            try store.save(journal)
            return journal
        } catch {
            markRemovalNeedsAttention(&journal, removalID: selected.id, reason: String(describing: error))
            try? store.save(journal)
            throw RecoveryError.unsafe(RecoveryError.reason(of: error))
        }
    }

    /// Only explicit Show/back supplies the input callbacks. Online is not proof
    /// of the selected monitor input, nor permission to unmirror. Both locks
    /// remain held across the input attempt, at most one re-selection
    /// (`relinkInput` returns whether it wrote) and all read-only observations.
    private func prepareShow(_ journal: RecoveryJournal, baseline: RecoverySnapshot,
                             target: RecoveryDisplay, source: RecoveryDisplay, returnedTargets: Set<String> = [],
                             store: RecoveryStore,
                             returnInputBeforeRestore: ((RecoveryDisplay) throws -> DisplayInputOutcome.State)?,
                             relinkInput: ((RecoveryDisplay) throws -> Bool)?) throws -> RecoverySnapshot {
        // A follower whose input Show together already returned needs its saved modes too.
        let removals = (journal.publicMirrorSession?.removals ?? []).filter { !returnedTargets.contains($0.targetUUID) }
        // The input return can make macOS renumber displays; the caller
        // adopts that into the journal once the topology settles.
        func readyModes(_ observed: RecoverySnapshot) throws -> RecoverySnapshot {
            let renumbered = try baseline.renumbered(to: observed).remoded(available: availableModes)
            try renumbered.validateRestoration(to: observed)
            try validateShowAvailability(target: renumbered.displays.first { $0.uuid == target.uuid } ?? target,
                                         source: renumbered.displays.first { $0.uuid == source.uuid } ?? source)
            return MirrorSessionTopology.showModeBaseline(renumbered, removals: removals, showing: target.uuid,
                                                          current: observed)
        }
        let current = try engine.capture()
        let modes = try readyModes(current)
        do {
            try preflightModes(modes)
        } catch let error as RecoveryError {
            // Only the selected monitor's missing mode can be addressed by
            // this input return. Never switch another removal's input.
            guard case .modeUnavailable(let uuid, _, _) = error,
                  uuid.caseInsensitiveCompare(target.uuid) == .orderedSame,
                  returnInputBeforeRestore != nil else { throw error }
        }
        guard let returnInputBeforeRestore else { return current }
        guard Self.sameStoredJournal(journal, try store.load()) else {
            throw RecoveryError.unsafe("journal changed before input return; inspect recovery status")
        }
        let returned = try returnInputBeforeRestore(target)
        if returned == .notRequested {
            try preflightModes(modes)
            return current
        }
        let switched = returned.mayHaveSwitched

        // Persisted per-attempt outcome changes, e.g. "0:ready#1a2b3c4d | 9:<error reason>".
        var trace: [String] = []
        var relinked = !switched
        func note(_ attempt: Int, _ outcome: String) {
            if trace.last.map({ $0.drop(while: { $0 != ":" }).dropFirst() == outcome }) != true {
                trace.append("\(attempt):\(outcome)")
            }
        }
        let preInputIdentity = current.stableTopologyIdentity()
        defer {
            showSettleLogger.notice("show-settle target=\(target.uuid, privacy: .public) switched=\(switched) relinked=\(relinked) pre=\(preInputIdentity?.prefix(8) ?? "none", privacy: .public) trace=\(trace.joined(separator: " | "), privacy: .public)")
        }

        // Input return can reconnect the target and reinstate *both* mirrors;
        // never restore from the pre-input topology or consider mirror return
        // a Show. An unchanged input settles on two matching ready samples
        // within five seconds. A switched input makes the monitor relink some
        // seconds later (Auto Select off), so within 20 seconds it needs relink
        // evidence (target unready or topology changed) followed by three
        // seconds of unchanged ready topology, or five seconds of continuous
        // ready stability. A relink can cascade through every display in the
        // same hardware mirror set for seconds; unmirroring during that storm
        // preceded a kernel panic (2026-11-08), so one quiet sample isn't enough.
        func settle(from preIdentity: String?, switched: Bool) throws -> RecoverySnapshot {
            let lastAttempt = switched ? 99 : 25
            let quietMatches = 25
            let relinkQuietMatches = 15
            relinked = !switched
            var changed = false
            var previous: String?
            var matches = 0
            for attempt in 0...lastAttempt {
                guard Self.sameStoredJournal(journal, try store.load()) else {
                    throw RecoveryError.unsafe("journal changed during input return; inspect recovery status")
                }
                do {
                    let observed = try engine.capture()
                    try preflightModes(readyModes(observed))
                    let identity = observed.stableTopologyIdentity()
                    if identity != preIdentity { relinked = true; changed = true }
                    note(attempt, "ready#\(identity?.prefix(8) ?? "none")")
                    matches = identity != nil && identity == previous ? matches + 1 : 0
                    previous = identity
                    if matches >= (changed ? relinkQuietMatches : relinked ? 1 : quietMatches) {
                        guard Self.sameStoredJournal(journal, try store.load()) else {
                            throw RecoveryError.unsafe("journal changed during input return; inspect recovery status")
                        }
                        return observed
                    }
                    if attempt == lastAttempt {
                        throw RecoveryError.unsafe("display topology did not settle after input return; retry Show when stable; journal retained")
                    }
                } catch {
                    note(attempt, RecoveryError.reason(of: error))
                    relinked = true
                    changed = true
                    previous = nil
                    matches = 0
                    if attempt == lastAttempt { throw error }
                }
                engine.convergencePause()
            }
            throw RecoveryError.unsafe("display topology did not settle after input return; journal retained")
        }
        do {
            let settled = try settle(from: preInputIdentity, switched: switched)
            // A monitor that stays linked through the return (S2721DGF) can keep a
            // dead link the Mac retrained while it showed another input: no
            // picture, no hotplug. Re-selecting its input once forces the relink.
            guard switched, !relinked, let relinkInput, try relinkInput(target) else { return settled }
            trace.append("reselected")
            return try settle(from: settled.stableTopologyIdentity(), switched: true)
        } catch RecoveryError.modeUnavailable(let uuid, let mode, let name)
            where [.verified, .alreadySelected].contains(returned) && uuid.caseInsensitiveCompare(target.uuid) == .orderedSame {
            // Switching a monitor confirmed on its Mac input again won't bring the mode back.
            throw RecoveryError.unsafe("\(name ?? uuid) is on its Mac input, but macOS doesn't offer its saved mode \(mode). Turn it off and on or reconnect it, then retry Show. The journal is retained.")
        }
    }

    private func validateShowAvailability(target: RecoveryDisplay, source: RecoveryDisplay) throws {
        let available = try records()
        guard Set(available.map(\.id)).count == available.count,
              Set(available.compactMap { $0.uuid?.lowercased() }).count == available.count else {
            throw RecoveryError.unsafe("display identities are ambiguous; inspect recovery status")
        }
        for saved in [target, source] {
            guard let record = available.first(where: { $0.uuid?.caseInsensitiveCompare(saved.uuid) == .orderedSame }),
                  record.id == saved.id, record.vendor == saved.vendor, record.model == saved.model,
                  record.serial == saved.serial else {
                throw RecoveryError.unsafe("identity changed for \(saved.uuid); refusing to guess")
            }
            guard record.online, !record.asleep, saved.id != source.id || record.active else {
                throw RecoveryError.unsafe("journaled display \(saved.uuid) is asleep, inactive, or unavailable; wake or reconnect it before Show")
            }
        }
    }

    func verifyRemoval(store: RecoveryStore, selector: String?) throws -> RecoveryJournal {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try store.lock()
        defer { store.unlock() }
        var journal = try store.load()
        guard var session = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("recovery verify --display applies only to a public-mirror removal session")
        }
        let current = try engine.capture()
        reconcileSession(&journal, current: current, store: store)
        guard let reconciled = journal.publicMirrorSession else {
            throw RecoveryError.unsafe("public-mirror session disappeared; keep the journal")
        }
        session = reconciled
        let active = MirrorSessionTopology.activeRemovals(session.removals)
        let selected: PublicMirrorRemoval
        if let selector {
            let uuid: String
            if let parsed = UUID(uuidString: selector) {
                uuid = parsed.uuidString.lowercased()
            } else if let record = DisplaySelector.resolve(selector, in: try records()), let recordUUID = record.uuid {
                uuid = recordUUID.lowercased()
            } else {
                throw RecoveryError.unsafe("missing or ambiguous removal selector; use its captured UUID from recovery status")
            }
            if let disconnect = session.disconnects?.last(where: { $0.targetUUID == uuid }) {
                guard disconnect.state.resolved ||
                        (disconnect.state == .off && MirrorSessionTopology.matches(session, current: current)) else {
                    throw RecoveryError.unsafe(disconnect.failure ?? "the turned-off display needs attention; inspect recovery status")
                }
                return journal
            }
            guard let removal = session.removals.last(where: { $0.targetUUID == uuid }) else {
                throw RecoveryError.unsafe("selected display is not in this removal session")
            }
            selected = removal
        } else {
            guard active.count <= 1 else {
                throw RecoveryError.unsafe("several displays are removed; specify --display with one target UUID")
            }
            guard let only = active.first ?? session.removals.last else {
                throw RecoveryError.unsafe("removal session has no entries")
            }
            selected = only
        }
        if selected.state.resolved {
            guard (try? session.baseline.verify(current)) != nil || MirrorSessionTopology.matches(session, current: current) else {
                throw RecoveryError.unsafe("selected removal does not match its strictly verified restored state")
            }
            return journal
        }
        guard selected.state == .mirrored, MirrorSessionTopology.matches(session, current: current) else {
            throw RecoveryError.unsafe(selected.failure ?? "selected removal needs attention; inspect recovery status")
        }
        return journal
    }

    /// Caller holds both locks. Persists a same-boot renumbering of display IDs
    /// and then of modes (see RecoveryJournal.renumbered and remoded) before
    /// anything reads them. Anything it cannot prove is left for the stale-ID
    /// recovery path or the exact mode check.
    func adoptRenumbering(_ journal: inout RecoveryJournal, current: RecoverySnapshot, store: RecoveryStore) throws {
        if let renumbered = try? journal.renumbered(to: current) {
            try store.save(renumbered)
            let ids = zip(journal.snapshot.displays, renumbered.snapshot.displays)
                .map { "\($1.name ?? $1.uuid) \($0.id)→\($1.id)" }.joined(separator: ", ")
            showSettleLogger.notice("renumbered journal=\(renumbered.id.uuidString, privacy: .public) \(ids, privacy: .public)")
            journal = renumbered
        }
        guard let remoded = try? journal.remoded(to: current, available: availableModes) else { return }
        try store.save(remoded)
        let modes = zip(journal.snapshot.displays, remoded.snapshot.displays).filter { $0.mode != $1.mode }
            .map { "\($1.name ?? $1.uuid) mode \($0.mode.id)→\($1.mode.id)" }.joined(separator: ", ")
        showSettleLogger.notice("remoded journal=\(remoded.id.uuidString, privacy: .public) \(modes, privacy: .public)")
        journal = remoded
    }

    func reconcileSession(_ journal: inout RecoveryJournal, current: RecoverySnapshot, store: RecoveryStore) {
        guard var full = journal.publicMirrorSession else { return }
        if (try? full.baseline.verify(current)) != nil {
            for index in full.removals.indices {
                full.removals[index].state = .restored
                full.removals[index].failure = nil
                full.removals[index].restoreFrom = nil
            }
            full.disconnects = full.disconnects?.map { disconnect in
                guard !disconnect.state.resolved else { return disconnect }
                var settled = disconnect
                settled.state = disconnect.state == .turningOff ? .cancelled : .restored
                settled.failure = nil
                return settled
            }
            journal.publicMirrorSession = full
            journal.state = .verified
            journal.failure = nil
            journal.trigger = "system-restoration-verified"
            if full.removals.count != 1 {
                journal.mirrorTargetID = nil
                journal.mirrorSourceID = nil
            }
            try? store.save(journal)
            return
        }
        var changed = false
        // Settle only an interrupted private write. A display macOS turned
        // back on stays recorded until Show puts it back without a private write.
        full.disconnects = full.disconnects?.map { disconnect in
            var settled = disconnect
            switch (disconnect.state, current.displays.contains { $0.uuid == disconnect.targetUUID }) {
            case (.turningOff, true):
                settled.state = .cancelled
                settled.failure = nil
            case (.turningOff, false):
                settled.state = .needsAttention
                settled.failure = "The display disappeared before Turn off completed."
            case (.reconnecting, false):
                settled.state = .needsAttention
                settled.failure = DisplayTurnOff.didNotReturn
            default:
                return disconnect
            }
            changed = true
            return settled
        }
        let turnedOff = full.turnedOff
        var session = full.visible(in: current)
        func save() {
            full.adoptRemovals(from: session)
            journal.publicMirrorSession = full
            if full.removals.count != 1 {
                journal.mirrorTargetID = nil
                journal.mirrorSourceID = nil
            }
            try? store.save(journal)
        }
        // A wake transaction also promises exact visible modes/origins. The
        // ordinary mirror predicate is weaker and must not erase its failed
        // verification or an interrupted commit on the next inspection. A
        // failed one clears only once its full wake layout is observed, e.g.
        // after an off-input monitor returns into its mirror.
        if journal.trigger == "wake-resume", journal.state != .mirrored, !journal.state.resolved,
           !(journal.state == .needsAttention &&
             MirrorSessionTopology.activeRemovals(session.removals).allSatisfy({ $0.restoreFrom == nil }) &&
             MirrorSessionTopology.matchesWakeLayout(baseline: session.baseline, removals: session.removals,
                                                     current: current, turnedOff: turnedOff)) {
            if changed { save() }
            return
        }
        // An interrupted Hide that moved other removals completes only when
        // the moved topology is observed; otherwise they keep their source.
        for mover in MirrorSessionTopology.activeRemovals(session.removals) {
            let moved = MirrorSessionTopology.moving(session.removals, onto: mover)
            if moved != session.removals,
               MirrorSessionTopology.matches(baseline: session.baseline, removals: moved, current: current,
                                             turnedOff: turnedOff) {
                session.removals = moved
                changed = true
            }
        }
        if MirrorSessionTopology.matches(baseline: session.baseline, removals: session.removals, current: current,
                                         turnedOff: turnedOff) {
            for index in session.removals.indices where !session.removals[index].state.resolved {
                if session.removals[index].state != .mirrored || session.removals[index].failure != nil ||
                    session.removals[index].restoreFrom != nil {
                    session.removals[index].state = .mirrored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                }
            }
        } else {
            for index in session.removals.indices where !session.removals[index].state.resolved {
                let removal = session.removals[index]
                // An interrupted or retried Show resolves only by its own
                // durable postcondition, never by a later, weaker inspection.
                if let before = removal.restoreFrom,
                   (try? MirrorSessionTopology.verifyPartialShow(baseline: session.baseline, removals: session.removals,
                                                                 removalID: removal.id, before: before,
                                                                 current: current, turnedOff: turnedOff)) != nil {
                    session.removals[index].state = .restored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                guard MirrorSessionTopology.pendingShowSurvivorsMatch(removal, baseline: session.baseline, current: current) else {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = removal.failure ?? "Show changed another visible display; keep recovery"
                    changed = true
                    continue
                }
                if MirrorSessionTopology.activeRemovals(session.removals).count > 1,
                   MirrorSessionTopology.matchesBeforeOperation(removal, current: current) {
                    session.removals[index].state = .cancelled
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                var proposed = session.removals
                proposed[index].state = .restored
                if MirrorSessionTopology.targetMatchesBaseline(removal.targetUUID, baseline: session.baseline, current: current),
                   MirrorSessionTopology.matches(baseline: session.baseline, removals: proposed, current: current,
                                                 turnedOff: turnedOff) {
                    session.removals[index].state = .restored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                    continue
                }
                let target = current.displays.first(where: { $0.uuid == removal.targetUUID })
                let targetStillMirrored = target?.mirrorUUID?
                    .caseInsensitiveCompare(removal.sourceUUID) == .orderedSame
                // A sleeping source reports no followers, so a connected pair
                // with neither drawable proves nothing; wake re-inspects.
                let pairDark = target?.active == false &&
                    current.displays.first(where: { $0.uuid == removal.sourceUUID })?.active == false
                if !targetStillMirrored, !pairDark {
                    session.removals[index].state = .needsAttention
                    session.removals[index].failure = "The display is no longer mirrored as Hide left it."
                    changed = true
                } else if session.removals[index].state == .captured || session.removals[index].state == .restoring {
                    session.removals[index].state = .mirrored
                    session.removals[index].failure = nil
                    session.removals[index].restoreFrom = nil
                    changed = true
                }
            }
        }
        let unresolved = MirrorSessionTopology.activeRemovals(session.removals)
        let previousJournalState = journal.state
        let attention = unresolved.first(where: { $0.state == .needsAttention }).map(\.failure) ??
            full.unresolvedDisconnects.first(where: { $0.state == .needsAttention }).map(\.failure)
        if let attention {
            journal.state = .needsAttention
            journal.failure = attention
            changed = true
        } else if !unresolved.isEmpty || !turnedOff.isEmpty {
            journal.state = .mirrored
            journal.failure = nil
            changed = changed || previousJournalState != .mirrored
        } else if full.removals.isEmpty, !journal.state.resolved {
            // Only a cancelled Turn off remains: nothing is hidden, so even a
            // changed layout has nothing left to Show.
            journal.state = .restored
            journal.failure = nil
            changed = true
        }
        if changed { save() }
    }

    private func markRemovalNeedsAttention(_ journal: inout RecoveryJournal, removalID: UUID, reason: String) {
        guard var session = journal.publicMirrorSession,
              let index = session.removals.firstIndex(where: { $0.id == removalID }) else { return }
        session.removals[index].state = .needsAttention
        session.removals[index].failure = reason
        journal.publicMirrorSession = session
        journal.state = .needsAttention
        journal.failure = reason
    }

    func matches(_ expected: DisplayHideIdentity, record: DisplayRecord) -> Bool {
        expected.uuid.caseInsensitiveCompare(record.uuid ?? "") == .orderedSame &&
            expected.displayID == record.id && expected.vendor == record.vendor &&
            expected.model == record.model && expected.serial == record.serial
    }

    private func fallback(_ error: Error, store: RecoveryStore, selector: String? = nil) -> RecoveryError {
        let path = "'" + store.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let failure = RecoveryError.reason(of: error)
        let session = try? store.load().publicMirrorSession
        let removals = session?.removals ?? []
        let activeCount = MirrorSessionTopology.activeRemovals(removals).count
        let target = selector ?? (activeCount == 1 ? MirrorSessionTopology.activeRemovals(removals).first?.targetUUID : nil)
        let restoreCommand: String
        if session != nil, activeCount > 1, let target {
            let escaped = target.replacingOccurrences(of: "'", with: "'\\''")
            restoreCommand = "dp recovery restore --display '\(escaped)' --journal \(path)"
        } else if session != nil, activeCount > 1 {
            restoreCommand = "dp recovery status --journal \(path) (then select one target with recovery restore --display <UUID>)"
        } else {
            restoreCommand = "dp recovery restore --journal \(path)"
        }
        let guidance = failure.contains(MirrorRecoveryGuidance.manualSteps)
            ? "" : " \(MirrorRecoveryGuidance.manualSteps)"
        return .unsafe("\(failure). Journal kept. After inspecting recovery status and with explicit approval, fallback: \(restoreCommand). Changed identity/rotation/color may require manual correction first; no automatic retry.\(guidance)")
    }
}
