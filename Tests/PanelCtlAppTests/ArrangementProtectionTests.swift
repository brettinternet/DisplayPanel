import XCTest
import CoreGraphics
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class ArrangementProtectionTests: XCTestCase {
    private var suites: [String] = []
    private var models: [AppModel] = []

    override func tearDown() {
        for model in models { model.shutdown {} }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        models = []
        suites = []
        super.tearDown()
    }

    private final class State {
        var layout: PanelCtlCore.DisplayArrangement = initialLayout()
        private static func initialLayout() -> PanelCtlCore.DisplayArrangement {
            var members: [DisplayArrangementMember] = []
            for index in 1...3 {
                let uuid = String(format: "00000000-0000-0000-0000-%012d", index)
                let origin = Int32((index - 1) * 1920)
                members.append(DisplayArrangementMember(uuid: uuid, id: UInt32(index), name: "Display \(index)",
                    vendor: 1, model: UInt32(index), serial: UInt32(index), x: origin, y: 0,
                    width: 1920, height: 1080, rotation: 0, main: index == 1))
            }
            return PanelCtlCore.DisplayArrangement(members: members)
        }
        static func mode(width: Int = 1920, rate: Double = 240) throws -> RecoveryMode {
            try JSONDecoder().decode(RecoveryMode.self, from: JSONSerialization.data(withJSONObject: [
                "id": width, "width": width, "height": 1080, "pixelWidth": width * 2,
                "pixelHeight": 2160, "refreshRate": rate, "flags": 0
            ]))
        }
        var modes: [String: RecoveryMode] = [:]
        var modeOffered = true
        var mirrored: Set<UInt32> = []
        var modeWrites = 0
        var modeLockHeld = false
        var modeFailure = false
        var modeOnWrite: (() -> Void)?
        var modeBeforeBoundary: (() -> Void)?
        var order: [String] = []
        var date = Date()
        var journal = DisplayHandoffStatus(state: .none, journalPath: "/tmp/panelctl-arrangement-fake/current.json")
        var writes = 0
        var failWrite = false
        var captureFailure = false
        var onWrite: (() -> Void)?
        var beforeBoundary: (() -> Void)?
        var records: [DisplayRecord] {
            layout.members.enumerated().map { index, member in
                DisplayRecord(index: index + 1, id: member.id, uuid: member.uuid, name: member.name,
                    active: true, online: true, asleep: false, builtin: false, main: member.main,
                    vendor: member.vendor, model: member.model, serial: member.serial,
                    bounds: DisplayBounds(CGRect(x: Double(member.x), y: Double(member.y), width: member.width, height: member.height)),
                    pixelWidth: Int(member.width), pixelHeight: Int(member.height))
            }
        }
    }

    private func makeModel(_ state: State, preferences: ArrangementPreferences? = nil,
                           defaults existing: UserDefaults? = nil) throws -> (AppModel, UserDefaults) {
        let defaults: UserDefaults
        if let existing { defaults = existing }
        else {
            let suite = "panelctl-arrangement-app-\(UUID().uuidString)"
            suites.append(suite)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }
        if let preferences {
            defaults.set(try JSONEncoder().encode(preferences), forKey: AppModel.arrangementPreferencesKey)
        }
        let model = AppModel(defaults: defaults, displayProvider: { state.records }, now: { state.date },
            idleSecondsProvider: { nil }, isDisplayMirrored: { state.mirrored.contains($0) }, inspectHandoff: {
                state.modeLockHeld ? DisplayHandoffStatus(state: .busy, journalPath: state.journal.journalPath) : state.journal
            },
            coverDisplays: { _ in [] }, quiesceProtection: { $0(true, nil) }, displayWakeSettleDelay: 0.01,
            captureArrangement: { excluded in
                if state.captureFailure { throw ArrangementProtectionError("Topology is still changing.") }
                let result = DisplayArrangement(members: state.layout.members.filter { !excluded.contains($0.uuid.lowercased()) })
                try result.validate()
                return result
            }, writeArrangement: { desired, expected, excluded, revalidate in
                state.beforeBoundary?()
                try revalidate()
                let current = DisplayArrangement(members: state.layout.members.filter { !excluded.contains($0.uuid.lowercased()) })
                guard current == expected else { throw ArrangementProtectionError("Topology changed at write boundary.") }
                guard !current.samePlacement(as: desired) else { return false }
                state.writes += 1
                state.order.append("arrangement")
                state.onWrite?()
                if state.failWrite { throw ArrangementProtectionError("Arrangement did not verify.") }
                state.layout = desired
                try revalidate()
                return true
            }, captureMode: { uuid in
                let display = try XCTUnwrap(state.records.first { $0.uuid == uuid })
                return SavedDisplayMode(display: display, mode: try state.modes[uuid] ?? State.mode())
            }, modeAvailable: { _ in state.modeOffered }, writeMode: { saved, revalidate in
                state.modeLockHeld = true
                defer { state.modeLockHeld = false }
                state.modeBeforeBoundary?()
                try revalidate()
                state.modeWrites += 1
                state.order.append("mode")
                state.modeOnWrite?()
                if state.modeFailure { throw ArrangementProtectionError("Saved display mode did not verify.") }
                state.modes[saved.uuid] = saved.mode
                if let index = state.layout.members.firstIndex(where: { $0.uuid == saved.uuid }) {
                    state.layout.members[index].width = Double(saved.mode.width)
                }
                try revalidate()
                return true
            })
        models.append(model)
        return (model, defaults)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Arrangement operation did not settle")
    }

    func testRememberIsExplicitPersistsExactSetsAndOffKeepsThem() throws {
        let state = State()
        let (model, defaults) = try makeModel(state)
        XCTAssertFalse(model.arrangementPreferences.enabled)
        XCTAssertFalse(model.arrangementPreferences.applyOnLaunch)
        try model.rememberCurrentArrangement()
        let first = try XCTUnwrap(model.arrangementPreferences.remembered.first)
        XCTAssertEqual(first.relationships?.count, 2)
        state.layout.members[1].x += 100
        model.refreshDisplays()
        XCTAssertTrue(model.arrangementStatus.differs)
        XCTAssertTrue(model.arrangementStatus.canRemember)
        XCTAssertEqual(model.arrangementPreferences.remembered, [first], "drift never updates saved preferences")
        model.setArrangementProtectionEnabled(true)
        model.setArrangementProtectionEnabled(false)
        let (reloaded, _) = try makeModel(state, defaults: defaults)
        XCTAssertEqual(reloaded.arrangementPreferences.remembered, [first])
        XCTAssertFalse(reloaded.arrangementPreferences.enabled)
        state.layout.members.removeLast()
        try reloaded.rememberCurrentArrangement()
        XCTAssertEqual(reloaded.arrangementPreferences.remembered.count, 2)
        try reloaded.forgetArrangement(setKey: first.setKey)
        XCTAssertEqual(reloaded.arrangementPreferences.remembered.count, 1)
        state.layout.members.removeLast()
        XCTAssertThrowsError(try reloaded.rememberCurrentArrangement())
        XCTAssertEqual(state.writes, 0)
    }

    func testReconnectRepairsOnceButManualChangesAndOwnNotificationsDoNot() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        try model.rememberCurrentArrangement()
        model.setArrangementProtectionEnabled(true)
        let saved = state.layout
        state.layout.members[1].x += 200
        model.displayParametersChanged()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.writes, 0, "manual layout changes are not transitions")
        state.onWrite = { [weak model] in
            model?.displayReconfigured(display: 2, flags: .addFlag)
            model?.displayParametersChanged()
        }
        model.displayReconfigured(display: 2, flags: .addFlag)
        try await waitFor { state.writes == 1 }
        XCTAssertTrue(state.layout.samePlacement(as: saved))
        state.layout.members[1].x += 400
        model.displayReconfigured(display: 2, flags: .addFlag, ownOperation: true)
        model.displayReconfigured(display: 2, flags: .movedFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.writes, 1)
        XCTAssertEqual(model.arrangementStatus.state, "remembered")
        XCTAssertTrue(model.arrangementStatus.differs)
    }

    func testWakeAndApplyOnLaunchRestoreMainOnlyAfterSettlement() async throws {
        let state = State()
        let saved = state.layout
        let preferences = ArrangementPreferences(enabled: true, applyOnLaunch: false, remembered: [saved])
        state.layout = try XCTUnwrap(state.layout.preferringMain(state.layout.members[1]))
        let (model, _) = try makeModel(state, preferences: preferences)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.writes, 0, "launch opt-in is separate")
        model.beginDisplaySleepTransition()
        model.displayWakeObserved(screensAwake: false)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.writes, 0)
        model.displayWakeObserved(screensAwake: true)
        try await waitFor { state.writes == 1 }
        XCTAssertTrue(state.layout.samePlacement(as: saved))

        let launch = State()
        launch.layout.members[1].x += 300
        _ = try makeModel(launch, preferences: ArrangementPreferences(enabled: true, applyOnLaunch: true, remembered: [saved]))
        try await waitFor { launch.writes == 1 }
        XCTAssertTrue(launch.layout.samePlacement(as: saved))
    }

    func testPreferredMainPreservesRelativePlacementIsAbsentOrHiddenNoOpAndSavedSetWins() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        let preferred = state.layout.members[1]
        try model.setArrangementPreferredMain(uuid: preferred.uuid)
        model.setArrangementProtectionEnabled(true)
        XCTAssertEqual(model.arrangementStatus.state, "preferred-main")
        let relative = state.layout.members[2].x - state.layout.members[1].x
        model.displayReconfigured(display: 2, flags: .addFlag)
        try await waitFor { state.writes == 1 }
        XCTAssertEqual(state.layout.members.first(where: \.main)?.uuid, preferred.uuid)
        XCTAssertEqual(state.layout.members[2].x - state.layout.members[1].x, relative)
        try model.rememberCurrentArrangement()
        try model.setArrangementPreferredMain(uuid: state.layout.members[0].uuid)
        XCTAssertEqual(model.arrangementStatus.state, "remembered")
        model.displayReconfigured(display: 1, flags: .addFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.writes, 1, "saved arrangement takes precedence")

        let absent = State()
        let (absentModel, _) = try makeModel(absent)
        try absentModel.setArrangementPreferredMain(uuid: absent.layout.members[2].uuid)
        absentModel.setArrangementProtectionEnabled(true)
        absent.layout.members.removeLast()
        absentModel.refreshDisplays()
        absentModel.displayReconfigured(display: 3, flags: .removeFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(absent.writes, 0)
        XCTAssertEqual(absentModel.arrangementStatus.state, "unprotected")

        let hidden = State()
        let (hiddenModel, _) = try makeModel(hidden)
        let uuid = hidden.layout.members[2].uuid
        try hiddenModel.setArrangementPreferredMain(uuid: uuid)
        hiddenModel.setArrangementProtectionEnabled(true)
        hiddenModel.hide(targetUUID: uuid, style: .blackOut)
        try await waitFor { hiddenModel.isBlackoutHidden(uuid) }
        hiddenModel.displayReconfigured(display: 3, flags: .addFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(hidden.writes, 0)
        XCTAssertEqual(hiddenModel.arrangementStatus.state, "unprotected")
    }

    func testResizedReconnectRepairsOnceAndStatusComparesAdaptedLayout() async throws {
        for (width, height, rotation) in [(2560.0, 1440.0, 0.0), (960.0, 540.0, 0.0), (1080.0, 1920.0, 90.0)] {
            let state = State()
            let (model, _) = try makeModel(state)
            try model.rememberCurrentArrangement()
            let saved = model.arrangementPreferences.remembered
            model.setArrangementProtectionEnabled(true)
            state.layout.members[0].width = width
            state.layout.members[0].height = height
            state.layout.members[0].rotation = rotation
            model.displayParametersChanged()
            try await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertEqual(state.writes, 0, "a mode change alone must not start correction")
            XCTAssertTrue(model.arrangementStatus.differs)
            model.displayReconfigured(display: 1, flags: .addFlag)
            try await waitFor { state.writes == 1 }
            XCTAssertEqual(state.layout.members.map(\.x), [0, Int32(width), Int32(width) + 1920])
            XCTAssertEqual(state.layout.members[0].rotation, rotation)
            XCTAssertTrue(state.layout.members[0].main)
            XCTAssertFalse(model.arrangementStatus.differs)
            XCTAssertEqual(model.arrangementStatus.state, "remembered")
            XCTAssertEqual(model.arrangementPreferences.remembered, saved, "adaptation must not overwrite the saved baseline")
            XCTAssertEqual(model.restoreArrangement().outcome, .noOp)
            XCTAssertEqual(state.writes, 1, "restoring the adapted layout again is a no-op")
        }
    }

    func testUnrepresentableSizeAndIdentityRefuseWithoutFallingBackToPreferredMain() throws {
        let state = State()
        let (model, _) = try makeModel(state)
        try model.rememberCurrentArrangement()
        try model.setArrangementPreferredMain(uuid: state.layout.members[1].uuid)
        model.setArrangementProtectionEnabled(true)
        state.layout.members[1].width = Double(Int32.max)
        XCTAssertEqual(model.arrangementStatus.state, "suspended")
        XCTAssertTrue(model.arrangementStatus.canRemember, "explicit Remember can replace stale geometry")
        XCTAssertEqual(model.restoreArrangement().outcome, .refused)
        state.layout.members[1].width = 1920
        state.layout.members[1].serial += 1
        XCTAssertEqual(model.restoreArrangement().outcome, .refused)
        state.layout.members[1] = state.layout.members[0]
        XCTAssertEqual(model.restoreArrangement().outcome, .refused)
        XCTAssertThrowsError(try model.rememberCurrentArrangement())
        XCTAssertEqual(state.writes, 0)
    }

    func testRecoverySuspendsRememberAndRestoreAndRevalidatesAtBoundary() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        try model.rememberCurrentArrangement()
        model.setArrangementProtectionEnabled(true)
        state.layout.members[1].x += 100
        state.journal = DisplayHandoffStatus(state: .unsupported, journalPath: "/tmp/fake/current.json", journalID: "unresolved")
        model.refreshDisplays()
        XCTAssertEqual(model.arrangementStatus.state, "suspended")
        XCTAssertThrowsError(try model.rememberCurrentArrangement())
        XCTAssertEqual(model.restoreArrangement().outcome, .refused)
        model.displayReconfigured(display: 2, flags: .addFlag)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.writes, 0)
        state.date = state.date.addingTimeInterval(20)
        try await waitFor { model.arrangementLastResult?.contains("15 seconds") == true }
        state.journal = DisplayHandoffStatus(state: .none, journalPath: "/tmp/fake/current.json")
        model.refreshDisplays()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.writes, 0, "expired transitions do not resume after recovery")
        state.beforeBoundary = { [weak model] in model?.beginDisplaySleepTransition() }
        XCTAssertFalse(model.restoreArrangement().ok)
        XCTAssertEqual(state.writes, 0)
    }

    func testTransientCaptureWaitsButFailedVerificationNeverRetries() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        try model.rememberCurrentArrangement()
        model.setArrangementProtectionEnabled(true)
        state.layout.members[1].x += 100
        state.captureFailure = true
        model.displayReconfigured(display: 2, flags: .addFlag)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.writes, 0)
        state.captureFailure = false
        state.failWrite = true
        try await waitFor { state.writes == 1 }
        XCTAssertTrue(model.arrangementLastResult?.contains("did not verify") == true)
        model.displayParametersChanged()
        model.displayReconfigured(display: 2, flags: .movedFlag)
        model.displayReconfigured(display: 2, flags: .addFlag, ownOperation: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.writes, 1)
    }

    func testModeRememberIsExplicitOffByDefaultAndPersistsWithoutImplicitReplacement() throws {
        let state = State()
        let (model, defaults) = try makeModel(state)
        let uuid = state.layout.members[0].uuid
        XCTAssertTrue(model.modePreferences.displays.isEmpty)
        try model.rememberCurrentMode(uuid: uuid)
        let saved = try XCTUnwrap(model.modePreferences.displays.first)
        XCTAssertFalse(saved.enabled)
        try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
        state.modes[uuid] = try State.mode(rate: 60)
        model.refreshDisplays()
        try model.setModeProtectionEnabled(uuid: uuid, enabled: false)
        let (reloaded, _) = try makeModel(state, defaults: defaults)
        XCTAssertEqual(reloaded.modePreferences.displays.first?.saved, saved.saved)
        XCTAssertFalse(try XCTUnwrap(reloaded.modePreferences.displays.first).enabled)
        try reloaded.rememberCurrentMode(uuid: uuid)
        XCTAssertEqual(reloaded.modePreferences.displays.first?.saved.mode.refreshRate, 60)
        try reloaded.forgetMode(uuid: uuid)
        XCTAssertTrue(reloaded.modePreferences.displays.isEmpty)
        XCTAssertEqual(state.modeWrites, 0)
    }

    func testModeInputReturnRunsBeforeArrangementAndIgnoresManualAndOwnChanges() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        let uuid = state.layout.members[0].uuid
        try model.rememberCurrentMode(uuid: uuid)
        try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
        try model.rememberCurrentArrangement()
        model.setArrangementProtectionEnabled(true)
        state.modes[uuid] = try State.mode(width: 1280, rate: 60)
        state.layout.members[0].width = 1280
        state.layout.members[1].x = 1280
        model.displayParametersChanged()
        model.displayReconfigured(display: 1, flags: .setModeFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.modeWrites, 0, "System Settings changes without a transition stand")
        state.modeOnWrite = { [weak model] in
            model?.displayReconfigured(display: 1, flags: .addFlag)
            model?.displayParametersChanged()
        }
        model.displayReconfigured(display: 1, flags: .addFlag)
        try await waitFor { state.writes == 1 }
        XCTAssertEqual(state.order, ["mode", "arrangement"])
        XCTAssertEqual(state.layout.members[1].x, 1920)
        XCTAssertEqual(state.modes[uuid]?.refreshRate, 240)
        state.modes[uuid] = try State.mode(rate: 60)
        model.displayReconfigured(display: 1, flags: .addFlag, ownOperation: true)
        model.displayReconfigured(display: 1, flags: .setModeFlag)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.modeWrites, 1)
    }

    func testModeLateArrivalAndDeadlineNeverApproximateOrRetryVerificationFailure() async throws {
        for outcome in ["late-success", "verification-failure", "deadline"] {
            let state = State()
            let (model, _) = try makeModel(state)
            let uuid = state.layout.members[0].uuid
            try model.rememberCurrentMode(uuid: uuid)
            try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
            state.modes[uuid] = try State.mode(rate: 60)
            state.modeOffered = false
            model.displayReconfigured(display: 1, flags: .addFlag)
            try await waitFor { model.modeResults[uuid]?.contains("unavailable") == true }
            XCTAssertEqual(state.modeWrites, 0)
            if outcome == "deadline" {
                state.date.addTimeInterval(16)
                try await waitFor { model.modeResults[uuid]?.contains("15 seconds") == true }
                state.modeOffered = true
                model.displayReconfigured(display: 1, flags: .setModeFlag)
                try await Task.sleep(nanoseconds: 40_000_000)
                XCTAssertEqual(state.modeWrites, 0)
            } else {
                state.modeFailure = outcome == "verification-failure"
                state.modeOffered = true
                try await waitFor { state.modeWrites == 1 }
                XCTAssertTrue(model.modeResults[uuid]?.contains(state.modeFailure ? "did not verify" : "Restored and verified") == true)
                if !state.modeFailure { XCTAssertEqual(state.modes[uuid]?.refreshRate, 240) }
                model.displayParametersChanged()
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertEqual(state.modeWrites, 1)
            }
        }
    }

    func testModeSkipsJournalAndMirrorAndRechecksWakeAtBoundary() async throws {
        for reason in ["journal", "mirror", "boundary"] {
            let state = State()
            let (model, _) = try makeModel(state)
            let uuid = state.layout.members[0].uuid
            try model.rememberCurrentMode(uuid: uuid)
            try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
            state.modes[uuid] = try State.mode(rate: 60)
            if reason == "journal" {
                state.journal = DisplayHandoffStatus(state: .unsupported, journalPath: "/tmp/fake/current.json", journalID: "unresolved")
            } else if reason == "mirror" {
                state.mirrored = [1]
            } else {
                state.modeBeforeBoundary = { [weak model] in model?.beginDisplaySleepTransition() }
            }
            model.displayReconfigured(display: 1, flags: .addFlag)
            try await Task.sleep(nanoseconds: 70_000_000)
            XCTAssertEqual(state.modeWrites, 0, reason)
            XCTAssertNotNil(model.modeResults[uuid])
        }
    }

    func testModeStaggeredReconnectKeepsMissingDisplayPendingWithoutReplenishingAttempts() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        let returning = state.layout.members[2]
        let waiting = state.layout.members[0].uuid
        for uuid in [returning.uuid, waiting] {
            try model.rememberCurrentMode(uuid: uuid)
            try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
            state.modes[uuid] = try State.mode(rate: 60)
        }
        state.modeOffered = false
        state.layout.members.removeLast()
        model.displayReconfigured(display: returning.id, flags: .removeFlag)
        try await waitFor { model.modeResults[returning.uuid]?.contains("reconnect") == true && model.modeResults[waiting]?.contains("unavailable") == true }
        state.layout.members.append(returning)
        state.modeOffered = true
        model.displayReconfigured(display: returning.id, flags: .addFlag)
        try await waitFor { state.modeWrites == 2 }
        XCTAssertEqual(state.modes[returning.uuid]?.refreshRate, 240)
        XCTAssertEqual(state.modes[waiting]?.refreshRate, 240)
        XCTAssertEqual(state.modeWrites, 2)
    }

    func testLaterRelinkRechecksMatchingModeButNeverReplenishesAWriteAttempt() async throws {
        let state = State()
        let (model, _) = try makeModel(state)
        let first = state.layout.members[0]
        let returning = state.layout.members[2]
        for uuid in [first.uuid, returning.uuid] {
            try model.rememberCurrentMode(uuid: uuid)
            try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
        }
        state.layout.members.removeLast()
        state.modes[returning.uuid] = try State.mode(rate: 60)
        model.displayReconfigured(display: returning.id, flags: .removeFlag)
        try await waitFor {
            model.modeResults[first.uuid]?.contains("already matches") == true &&
                model.modeResults[returning.uuid]?.contains("reconnect") == true
        }
        state.modes[first.uuid] = try State.mode(rate: 60)
        model.displayReconfigured(display: first.id, flags: .setModeFlag)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.modeWrites, 0, "a matching observation is only reopened by another transition")
        model.displayReconfigured(display: first.id, flags: .addFlag)
        try await waitFor { state.modeWrites == 1 }
        XCTAssertEqual(state.modes[first.uuid]?.refreshRate, 240)

        state.modes[first.uuid] = try State.mode(rate: 60)
        model.displayReconfigured(display: first.id, flags: .addFlag)
        state.layout.members.append(returning)
        model.displayReconfigured(display: returning.id, flags: .addFlag)
        try await waitFor { state.modes[returning.uuid]?.refreshRate == 240 }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.modeWrites, 2, "only the display without an attempt can be restored")
        XCTAssertEqual(state.modes[first.uuid]?.refreshRate, 60, "an actual write consumes the attempt for the whole batch")
    }

    func testRealReconnectDuringLaunchSettlementRestoresModeBeforeArrangement() async throws {
        let state = State()
        let (model, defaults) = try makeModel(state)
        let uuid = state.layout.members[0].uuid
        try model.rememberCurrentMode(uuid: uuid)
        try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
        try model.rememberCurrentArrangement()
        model.setArrangementProtectionEnabled(true)
        model.setArrangementApplyOnLaunch(true)
        state.modes[uuid] = try State.mode(width: 1280, rate: 60)
        state.layout.members[0].width = 1280
        state.layout.members[1].x = 1280
        state.captureFailure = true
        let (reloaded, _) = try makeModel(state, defaults: defaults)
        try await waitFor { reloaded.arrangementLastResult?.contains("changing") == true }
        XCTAssertEqual(state.modeWrites, 0, "launch itself cannot restore modes")
        reloaded.displayReconfigured(display: 1, flags: .addFlag)
        state.captureFailure = false
        try await waitFor { state.writes == 1 }
        XCTAssertEqual(state.order, ["mode", "arrangement"])
        XCTAssertEqual(state.layout.members[1].x, 1920)
    }

    func testModeWakeRestoresOnlyAfterResumeAndDoesNotApplyOnLaunch() async throws {
        let state = State()
        let (model, defaults) = try makeModel(state)
        let uuid = state.layout.members[0].uuid
        try model.rememberCurrentMode(uuid: uuid)
        try model.setModeProtectionEnabled(uuid: uuid, enabled: true)
        state.modes[uuid] = try State.mode(rate: 60)
        let (reloaded, _) = try makeModel(state, defaults: defaults)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.modeWrites, 0)
        reloaded.beginDisplaySleepTransition()
        reloaded.displayWakeObserved(screensAwake: false)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.modeWrites, 0)
        reloaded.displayWakeObserved(screensAwake: true)
        try await waitFor { state.modeWrites == 1 }
        XCTAssertEqual(state.modes[uuid]?.refreshRate, 240)
    }

    func testExplicitRestoreThroughCLITransportAndActionSharesChecks() async throws {
        let state = State()
        let (model, defaults) = try makeModel(state)
        try model.rememberCurrentArrangement()
        state.layout.members[1].x += 100
        let delegate = AppDelegate()
        delegate.model = model
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-arrange-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { request, received in
            await delegate.handleControlRequest(request, receivedAt: received)
        }
        try server.start()
        defer { server.stop() }
        let result = try await Task.detached {
            try AppControlClient(socketPath: path, launch: { XCTFail("Restore must not launch the app") }).execute(.restoreArrangement)
        }.value
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(state.writes, 1)
        let status = await delegate.handleControlRequest(AppControlRequest(command: .status), receivedAt: .now)
        XCTAssertEqual(status.arrangement, model.arrangementStatus)
        XCTAssertEqual(model.handleArrangementControlRequest(AppControlRequest(command: .restoreArrangement, targetUUID: state.layout.members[0].uuid)).outcome, .refused)

        let action = DisplayAction(name: "Restore desktop", steps: [DisplayActionStep(effect: .restoreArrangement)])
        try model.saveDisplayAction(action)
        let decoded = try JSONDecoder().decode(DisplayActionSet.self, from: XCTUnwrap(defaults.data(forKey: AppModel.displayActionsKey)))
        XCTAssertEqual(decoded.actions.first, action)
        state.layout.members[1].x += 200
        let actionResult = await model.handleDisplayControlRequest(AppControlRequest(command: .runAction, actionID: action.id))
        XCTAssertEqual(actionResult.outcome, .done)
        XCTAssertEqual(actionResult.steps?.first?.effect, "restoreArrangement")
        XCTAssertNotNil(DisplayActionPresentation.alignedStepResults(for: action, steps: actionResult.steps))
        XCTAssertEqual(state.writes, 2)
        state.layout.members[1].rotation = 90
        state.layout.members[1].width = 1080
        state.layout.members[1].height = 1920
        let rotated = await model.handleDisplayControlRequest(AppControlRequest(command: .runAction, actionID: action.id))
        XCTAssertEqual(rotated.outcome, .done)
        XCTAssertEqual(state.layout.members[2].x, 3000)
        XCTAssertEqual(state.writes, 3)
        state.layout.members[1].serial += 1
        let refused = await model.handleDisplayControlRequest(AppControlRequest(command: .runAction, actionID: action.id))
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(state.writes, 3)
    }
}
