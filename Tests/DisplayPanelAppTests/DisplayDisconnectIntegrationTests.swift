import AppKit
import SwiftUI
import XCTest
@testable import DisplayPanelApp
@testable import DisplayPanelCore

@MainActor
final class DisplayDisconnectIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = try makeTestDirectory()
        defaults = try makeTestDefaults().defaults
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
    }

    private final class Fixture {
        let baseline: RecoverySnapshot
        var current: RecoverySnapshot
        let store: RecoveryStore
        var writes: [Bool] = []
        var arms = 0
        var fault = ""
        var clock: TimeInterval = 100
        var pending = false
        var finish: (() throws -> Void)?
        let uuid = "00000000-0000-0000-0000-000000000002"

        init(url: URL) throws {
            store = RecoveryStore(url: url)
            let uuid = self.uuid
            let connector = "IOService:/synthetic-native-framebuffer"
            let data: [String: Any] = ["bootSession": "fake-boot", "osBuild": "synthetic-build", "userID": getuid(), "hostModel": "Mac99,1",
                "displays": (1...2).map { id -> [String: Any] in
                    let location = id == 2 ? connector : "fake-survivor-port"
                    return ["uuid": id == 2 ? uuid : "00000000-0000-0000-0000-000000000001", "id": id,
                     "name": id == 2 ? "Synthetic external monitor" : "Synthetic survivor",
                     "vendor": id, "model": id, "serial": id * 100,
                     "builtin": false, "main": id == 1, "active": true, "x": (id - 1) * 1920, "y": 0, "rotation": 0,
                     "connector": location, "identityEvidence": ["source": "cgAndCoreDisplay", "capturedAt": 0,
                         "transport": "HDMI", "transportLocation": id == 2 ? "Port-HDMI/HDMI" : "fake-survivor",
                         "framebufferLocation": location],
                     "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920, "pixelHeight": 1080, "refreshRate": 60, "flags": 0]]
                }]
            baseline = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: data))
            current = baseline
        }

        lazy var session = RecoveryPrivateSession(snapshot: baseline, capture: { self.current }, inventory: {
            RecoveryEnableInventory(bootSession: self.baseline.bootSession, osBuild: self.baseline.osBuild,
                userID: self.baseline.userID, identities: self.baseline.displays.map { d in
                    RecoveryEnableIdentity(uuid: self.current.displays.contains { $0.id == d.id } ? d.uuid : nil,
                        id: d.id, vendor: d.vendor, model: d.model, serial: d.serial, builtin: d.builtin,
                        connector: d.connector!, transport: d.identityEvidence!.transport!,
                        framebufferLocation: d.identityEvidence?.framebufferLocation,
                        transportLocation: d.identityEvidence?.transportLocation)
                },
                onlineIDs: Set(self.current.displays.map(\.id)), hostModel: self.baseline.hostModel, architecture: "arm64",
                binding: self.fault == "identity" ? .unqualified : .captureMatch)
        }, environment: {
            RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
                lid: .notApplicable, mirrored: false, screens: Dictionary(uniqueKeysWithValues: self.current.displays.map {
                    ($0.id, .init(kind: self.fault == "survivor" && $0.main ? .headless : .physical,
                                online: true, active: true, awake: true))
                }))
        }, transaction: {
            RecoveryEnableTransaction(begin: { CGDisplayConfigRef(bitPattern: 1)! }, setEnabled: { _, id, enabled in
                XCTAssertEqual(id, 2)
                self.writes.append(enabled); self.pending = enabled
            }, commit: { _, scope in
                XCTAssertEqual(scope, .forSession)
                if self.fault == "reconnect" && self.pending { throw RecoveryError.unsafe("fake reconnect failure") }
                self.current = self.pending ? self.baseline : RecoverySnapshot(bootSession: self.baseline.bootSession,
                    osBuild: self.baseline.osBuild, userID: self.baseline.userID,
                    displays: [self.baseline.displays[0]], hostModel: self.baseline.hostModel)
            }, cancel: { _ in })
        }, apply: { _, _ in XCTFail("unexpected public restore") }, now: { self.clock }, initiallyAwake: true)

        var controller: DisplayDisconnectController {
            DisplayDisconnectController(store: store, capture: { self.current }, preflight: { _, id in
                _ = try self.session.prepareDisable(targetID: id)
            }, arm: { [self] store, _, timeout, snapshot, target in
                self.arms += 1
                if self.fault == "helper" { throw RecoveryError.unsafe("fake helper readiness failure") }
                XCTAssertEqual(timeout, 15)
                try store.lock()
                var journal = RecoveryJournal(snapshot: snapshot, timeout: timeout)
                journal.privateLease = true; journal.state = .armed
                try store.create(journal)
                let writer = try self.session.prepareDisable(targetID: target)
                try writer.perform(&journal, store: store, targetID: target, capture: { self.current }, lease: {})
                self.session.didDisable(target)
                // A real watchdog holds this lock in a separate process for its
                // whole lease; release it here so a fresh app process (the only
                // caller left once the lease and its deadline are simulated
                // separately below) can lock the same journal to reconnect.
                store.unlock()
                var finished = false
                self.finish = { [weak self] in
                    guard let self, !finished else { return }
                    finished = true
                    try store.lock()
                    defer { store.unlock() }
                    try self.session.engine.finish(&journal, store: store, verifyOnly: false, trigger: "deadline")
                }
                return DisplayDisconnectLease(id: journal.id, release: { [weak self] in try self?.finish?() })
            }, recover: { store, id in
                _ = try self.session.engine.recover(store: store, trigger: "app-reconnect", ownedOnly: true, expectedID: id)
            }, now: { self.clock })
        }

        var records: [DisplayRecord] {
            current.displays.enumerated().map { index, d in
                DisplayRecord(index: index + 1, id: d.id, uuid: d.uuid, name: d.name, active: true, online: true,
                    asleep: false, builtin: false, main: d.main, vendor: d.vendor, model: d.model, serial: d.serial,
                    bounds: DisplayBounds(CGRect(x: Int(d.x), y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
            }
        }
    }

    private func fixture(_ name: String = "current") throws -> Fixture {
        try Fixture(url: directory.appendingPathComponent("\(name).json"))
    }

    private func model(
        _ f: Fixture,
        extraDisplays: [DisplayRecord] = [],
        cover: @escaping (Set<UInt32>) -> Set<UInt32> = { _ in [] },
        quiesceProtection: ProtectionQuiesce? = nil,
        protectionCoordinator: ProtectionCoordinator? = nil,
        handoffStatusProvider: (() -> DisplayHandoffStatus)? = nil,
        now: @escaping () -> Date = Date.init
    ) -> AppModel {
        AppModel(defaults: defaults, displayProvider: { f.records + extraDisplays }, now: now,
            idleSecondsProvider: { 0 },
            sleepDisplays: { XCTFail("sleep must not run") }, isDisplayMirrored: { _ in false },
            inspectHandoff: handoffStatusProvider ?? {
                let status = try? f.controller.inspect()
                return DisplayHandoffStatus(state: status?.resolved == false ? .unsupported : .none,
                    journalPath: f.store.url.path, journalID: status?.journalID)
            },
            hideDisplay: { _, _, _ in throw RecoveryError.unsafe("no mirror writes") },
            showDisplay: { _, _ in throw RecoveryError.unsafe("no mirror writes") },
            checkDDCInput: { _ in throw RecoveryError.unsafe("no DDC") }, coverDisplays: cover,
            quiesceProtection: quiesceProtection, protectionCoordinator: protectionCoordinator,
            disconnectController: f.controller)
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous disconnect state", file: file, line: line)
        throw WaitTimeout()
    }

    private func protectionRule(_ name: String, uuid: String, idleSeconds: TimeInterval = 120) -> ProtectionRule {
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [uuid]
        settings.didChooseDisplays = true
        settings.idleSeconds = idleSeconds
        settings.followUpAction = .restore
        return ProtectionRule(name: name, isEnabled: true, settings: settings)
    }

    private func saveAutomationPreferences(_ preferences: AutomationPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: "automationRules")
    }

    private func automationCoordinator(
        directory: URL,
        cleanupIsVerified: @escaping () -> Bool = { true }
    ) -> ProtectionCoordinator {
        ProtectionCoordinator(
            verifyJournal: { _ in true },
            ruleJournalDirectory: directory,
            removeDeletedDirectories: false,
            serviceFactory: { ruleID in
                ProtectionService(
                    cleanupRuleID: ruleID,
                    cleanupIsVerified: cleanupIsVerified,
                    displaysAreAsleep: { false }
                )
            }
        )
    }

    private func writeAutomationHelper(ignoreTermination: Bool = false) throws -> URL {
        let helper = directory.appendingPathComponent("fake-dp")
        let script = """
        #!/bin/sh
        if [ "${DISPLAYPANEL_CLEANUP_ONLY:-}" = "1" ]; then
          printf 'cleanup\\n' >> "$DISPLAYPANEL_TEST_LOG"
          printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
          exit 0
        fi
        # Tests use watch as the launch-complete marker, so log its flag first.
        printf 'rearm %s\\n' "${DISPLAYPANEL_REARM_ON_START:-0}" >> "$DISPLAYPANEL_TEST_LOG"
        printf 'watch %s\\n' "$*" >> "$DISPLAYPANEL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        if [ "\(ignoreTermination ? "1" : "0")" = "1" ] && [ "${DISPLAYPANEL_IGNORE_TERM:-}" = "1" ]; then
          trap '' TERM
          while :; do /bin/sleep 0.05; done
        fi
        while IFS= read -r command; do
          if [ "$command" = "restore" ]; then
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
          fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private func launchLines(at log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    func testBlackOutRefusesDuringDisconnectLease() async throws {
        let f = try fixture()
        let third = DisplayRecord(index: 3, id: 3, uuid: "00000000-0000-0000-0000-000000000003", name: "Synthetic third",
            active: true, online: true, asleep: false, builtin: false, main: false, vendor: 3, model: 3, serial: 3,
            bounds: DisplayBounds(CGRect(x: 3840, y: 0, width: 1920, height: 1080)), pixelWidth: 1920, pixelHeight: 1080)
        var covers: [Set<UInt32>] = []
        let app = model(f, extraDisplays: [third], cover: { ids in covers.append(ids); return [] })
        let request = try f.controller.prepare(targetUUID: f.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        app.refreshDisconnectStatus()
        XCTAssertEqual(f.arms, 1)
        app.refreshDisplays()
        let survivor = try XCTUnwrap(app.displays.first { $0.main })
        XCTAssertEqual(app.blackoutReadiness(for: survivor)?.localizedDescription,
                       "Finish Full disconnect recovery first.")
        var result: DisplayOperationResult?
        app.hide(targetUUID: try XCTUnwrap(survivor.uuid)) { result = $0 }
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertTrue(covers.allSatisfy(\.isEmpty), "no cover is installed during the lease")
        try f.finish?()
    }

    func testUnsafeSelectionRefusesBeforeBackend() throws {
        let f = try fixture()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.baseline)) as! [String: Any]
        for field in ["main", "builtin", "active", "mirrorUUID", "duplicate", "uuid"] {
            var object = original
            var displays = object["displays"] as! [[String: Any]]
            switch field {
            case "main", "builtin": displays[1][field] = true
            case "active": displays[1][field] = false
            case "mirrorUUID": displays[1][field] = displays[0]["uuid"]
            case "duplicate": displays.append(displays[1])
            default: displays[1][field] = "invalid"
            }
            object["displays"] = displays
            let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            var controller = f.controller
            controller.capture = { snapshot }
            controller.preflight = { _, _ in XCTFail("unsafe selection reached backend: \(field)") }
            XCTAssertThrowsError(try controller.prepare(targetUUID: field == "uuid" ? "invalid" : f.uuid), field)
        }
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])
    }

    func testFailedAutomationCleanupBlocksConsentUntilExplicitRetry() async throws {
        let f = try fixture("cleanup-failure")
        let helper = try writeAutomationHelper()
        let log = directory.appendingPathComponent("cleanup-failure.log")
        setenv("DISPLAYPANEL_HELPER", helper.path, 1)
        setenv("DISPLAYPANEL_TEST_LOG", log.path, 1)
        defer { unsetenv("DISPLAYPANEL_HELPER"); unsetenv("DISPLAYPANEL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("External", uuid: f.uuid),
            protectionRule("Survivor", uuid: f.baseline.displays[0].uuid)
        ]))
        var cleanupVerified = true
        let coordinator = automationCoordinator(
            directory: directory.appendingPathComponent("cleanup-journals", isDirectory: true),
            cleanupIsVerified: { cleanupVerified }
        )
        let app = model(f, protectionCoordinator: coordinator)
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 2 }
        cleanupVerified = false
        // A CLI-started disconnect journal appears; the app only observes it.
        let request = try f.controller.prepare(targetUUID: f.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        app.refreshDisconnectStatus()
        try await waitUntil { app.protectionQuiescenceFailure != nil }
        XCTAssertEqual(f.arms, 1)
        XCTAssertEqual(f.writes, [false])
        XCTAssertTrue(app.statusSummary.contains("Automation paused"))

        cleanupVerified = true
        app.retryAutomationCleanup()
        try await waitUntil { app.protectionQuiescenceFailure == nil }
        XCTAssertEqual(f.arms, 1, "retry cleans up but never arms a new disconnect")
        XCTAssertEqual(f.writes, [false])
        // Cleanup alone doesn't resume automation while the disconnect journal
        // is still unresolved; rules only relaunch once recovery is verified.
        XCTAssertEqual(launchLines(at: log).filter { $0.hasPrefix("watch") }.count, 2)
        try f.finish?() // Fake watchdog deadline, through the real recovery engine.
        app.refreshCountdown()
        try await waitUntil { launchLines(at: log).filter { $0.hasPrefix("watch") }.count == 4 }
        XCTAssertEqual(f.arms, 1, "retry cleans up but never arms a new disconnect")
        XCTAssertEqual(f.writes, [false, true], "verified recovery reconnects the display")
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }

    func testRepairedPublicJournalReleasesPersistedDisconnectBlock() async throws {
        let f = try fixture("public-repaired")
        try f.store.lock()
        var journal = RecoveryJournal(snapshot: f.baseline)
        journal.state = .restored
        try f.store.create(journal)
        f.store.unlock()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.store.url.path)
        let app = model(f)
        XCTAssertNotNil(app.disconnectInspectionFailure, "unsafe permissions fail closed")
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.store.url.path)
        app.refreshCountdown()
        XCTAssertNil(app.disconnectInspectionFailure, "a readable public-only journal is not missing private evidence")
        XCTAssertFalse(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        let relaunched = model(f)
        XCTAssertNil(relaunched.disconnectInspectionFailure)
        XCTAssertFalse(ExperimentalDisconnectControls.isVisible(model: relaunched),
                        "a resolved, readable journal leaves no recovery to surface")

        try FileManager.default.removeItem(at: f.store.url)
        defaults.set(true, forKey: "disconnectRecoveryBlocked")
        let missing = model(f)
        XCTAssertNotNil(missing.disconnectInspectionFailure, "a missing journal still fails closed")
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in missing.shutdown { continuation.resume() } }
    }

    func testUnreadableDisconnectJournalFailsClosedAcrossRelaunch() async throws {
        let f = try fixture("unreadable")
        let corrupt = Data("not a recovery journal".utf8)
        try corrupt.write(to: f.store.url)
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Enabled rule", uuid: f.uuid)
        ]))
        let ruleJournalDirectory = directory.appendingPathComponent("unreadable-rule-journals", isDirectory: true)
        let app = model(f, protectionCoordinator: automationCoordinator(directory: ruleJournalDirectory))
        XCTAssertNotNil(app.disconnectInspectionFailure)
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        XCTAssertTrue(app.automationPreferences.isEnabled)
        XCTAssertEqual(app.disconnectJournalPath, f.store.url.path)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app))
        app.setExperimentalFeaturesEnabled(false)
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: app),
                      "unreadable recovery remains visible with Experimental features off")
        app.refreshCountdown()
        XCTAssertNotNil(app.disconnectInspectionFailure)
        XCTAssertEqual(try Data(contentsOf: f.store.url), corrupt)
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(f.writes, [])

        let relaunched = model(f, protectionCoordinator: automationCoordinator(directory: ruleJournalDirectory))
        XCTAssertNotNil(relaunched.disconnectInspectionFailure)
        XCTAssertTrue(relaunched.automationPreferences.isEnabled)
        XCTAssertEqual(try Data(contentsOf: f.store.url), corrupt)
        XCTAssertEqual(f.arms, 0, "relaunch never starts automation or private recovery against unreadable evidence")
        XCTAssertEqual(f.writes, [])
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
    }

    func testVerifiedRecoveryResumesAutomationButFailedRecoveryStaysPausedAcrossRelaunch() async throws {
        let helper = try writeAutomationHelper()
        let successfulFixture = try fixture("verified-resume")
        let successLog = directory.appendingPathComponent("verified-resume.log")
        setenv("DISPLAYPANEL_HELPER", helper.path, 1)
        setenv("DISPLAYPANEL_TEST_LOG", successLog.path, 1)
        defer { unsetenv("DISPLAYPANEL_HELPER"); unsetenv("DISPLAYPANEL_TEST_LOG") }
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Survivor rule", uuid: successfulFixture.baseline.displays[0].uuid)
        ]))
        let successCoordinator = automationCoordinator(
            directory: directory.appendingPathComponent("verified-resume-journals", isDirectory: true)
        )
        var handoffBusy = false
        var handoffReadCount = 0
        let successfulApp = model(
            successfulFixture,
            protectionCoordinator: successCoordinator,
            handoffStatusProvider: {
                handoffReadCount += 1
                return handoffBusy
                    ? DisplayHandoffStatus(state: .busy, journalPath: "/synthetic/handoff.json",
                                           reason: "synthetic journal lock busy", inspectionFailure: "synthetic journal lock busy")
                    : DisplayHandoffStatus(state: .none, journalPath: "/synthetic/handoff.json")
            }
        )
        try await waitUntil { launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count == 1 }
        // A CLI-started disconnect journal appears; the app only observes it.
        // Retain the lease; letting it deinit would reconnect immediately.
        let successRequest = try successfulFixture.controller.prepare(targetUUID: successfulFixture.uuid)
        let successLease = try successfulFixture.controller.disconnect(successRequest, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = successLease
        successfulApp.refreshDisconnectStatus()
        XCTAssertEqual(launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "disconnect lease holds the rule stopped")
        handoffBusy = true
        try successfulFixture.finish?()
        successfulApp.refreshCountdown()
        try await waitUntil { successfulApp.handoffInspectionFailure != nil && !successfulApp.protectionQuiescencePending }
        XCTAssertEqual(successfulApp.disconnectStatus?.resolved, true)
        XCTAssertEqual(launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "a transient handoff lock keeps the resumed helper stopped")
        handoffBusy = false
        let priorHandoffReads = handoffReadCount
        successfulApp.refreshCountdown()
        try await waitUntil { launchLines(at: successLog).filter { $0.hasPrefix("watch") }.count == 2 }
        XCTAssertGreaterThan(handoffReadCount, priorHandoffReads,
                             "an unchanged resolved disconnect journal still retries handoff inspection")
        XCTAssertNil(successfulApp.handoffInspectionFailure)
        XCTAssertEqual(Array(launchLines(at: successLog).filter { $0.hasPrefix("rearm") }.suffix(1)), ["rearm 1"],
                       "verified recovery sends the fresh-countdown rearm flag to the helper")
        XCTAssertTrue(successfulApp.disconnectStatus?.resolved == true)
        XCTAssertTrue(successfulApp.automationPreferences.isEnabled)
        await withCheckedContinuation { continuation in successfulApp.shutdown { continuation.resume() } }

        let failedFixture = try fixture("failed-resume")
        let failureLog = directory.appendingPathComponent("failed-resume.log")
        setenv("DISPLAYPANEL_TEST_LOG", failureLog.path, 1)
        try saveAutomationPreferences(AutomationPreferences(isEnabled: true, rules: [
            protectionRule("Survivor rule", uuid: failedFixture.baseline.displays[0].uuid)
        ]))
        let failureJournalDirectory = directory.appendingPathComponent("failed-resume-journals", isDirectory: true)
        let failedCoordinator = automationCoordinator(directory: failureJournalDirectory)
        let failedApp = model(failedFixture, protectionCoordinator: failedCoordinator)
        try await waitUntil { launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count == 1 }
        let failedRequest = try failedFixture.controller.prepare(targetUUID: failedFixture.uuid)
        // Retained; failedApp.reconnectDisconnect() below is the resolution path.
        let failedLease = try failedFixture.controller.disconnect(failedRequest, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = failedLease
        failedApp.refreshDisconnectStatus()
        failedFixture.fault = "reconnect"
        failedApp.reconnectDisconnect()
        XCTAssertEqual(failedApp.disconnectStatus?.state, "needsAttention")
        XCTAssertTrue(defaults.bool(forKey: "disconnectRecoveryBlocked"))
        try await waitUntil { !failedApp.protectionQuiescencePending }
        XCTAssertTrue(failedApp.statusSummary.contains("waiting for reconnect"))
        XCTAssertEqual(launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "failed recovery must not rearm the existing helper")

        let relaunched = model(failedFixture, protectionCoordinator: automationCoordinator(directory: failureJournalDirectory))
        XCTAssertEqual(relaunched.disconnectStatus?.state, "needsAttention")
        XCTAssertTrue(relaunched.statusSummary.contains("Automation paused"))
        XCTAssertTrue(relaunched.automationPreferences.isEnabled)
        XCTAssertEqual(launchLines(at: failureLog).filter { $0.hasPrefix("watch") }.count, 1,
                       "relaunch keeps automation paused instead of replaying the disconnect")
        await withCheckedContinuation { continuation in failedApp.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in relaunched.shutdown { continuation.resume() } }
    }

    func testAppToCoreFakeLeaseWatchdogAndReadOnlyRelaunch() async throws {
        let f = try fixture(), app = model(f)
        // A CLI-started disconnect journal appears; the app only observes it.
        let request = try f.controller.prepare(targetUUID: f.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        app.refreshDisconnectStatus()
        XCTAssertEqual(f.writes, [false]); XCTAssertEqual(f.arms, 1)
        let status = try XCTUnwrap(app.disconnectStatus)
        XCTAssertEqual(status.state, "disabled"); XCTAssertEqual(status.target?.displayID, 2)
        XCTAssertFalse(f.records.contains { $0.id == 2 })
        let original = try Data(contentsOf: f.store.url)
        let relaunched = model(f)
        relaunched.refreshCountdown()
        XCTAssertEqual(relaunched.disconnectStatus, status)
        XCTAssertEqual(try Data(contentsOf: f.store.url), original)
        XCTAssertEqual(f.writes, [false], "startup and polling must never write")
        XCTAssertTrue(ExperimentalDisconnectControls.isVisible(model: relaunched))
        try f.finish?() // Fake watchdog deadline, through the real recovery engine.
        app.refreshCountdown()
        XCTAssertEqual(f.writes, [false, true]); XCTAssertEqual(app.disconnectStatus?.resolved, true)
        app.refreshCountdown()
        XCTAssertEqual(f.writes, [false, true], "expiry never renews disconnect")
    }

    func testRefusalHelperFailureAndFailedReconnectPreserveEvidence() async throws {
        // identity/survivor refuse during preflight, before a journal is ever
        // armed; helper refuses during arming, after preflight passes.
        for fault in ["identity", "survivor", "helper"] {
            let f = try fixture(fault)
            f.fault = fault
            if fault == "helper" {
                let request = try f.controller.prepare(targetUUID: f.uuid)
                XCTAssertThrowsError(try f.controller.disconnect(
                    request, consent: true, executable: URL(fileURLWithPath: "/unused")), fault)
            } else {
                XCTAssertThrowsError(try f.controller.prepare(targetUUID: f.uuid), fault)
            }
            XCTAssertEqual(f.writes, [], fault)
        }

        // A CLI-started disconnect journal appears; the app only observes it,
        // and a failed reconnect leaves the journal unresolved for a relaunch.
        let f = try fixture("reconnect")
        f.fault = "reconnect"
        let app = model(f)
        let request = try f.controller.prepare(targetUUID: f.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        app.refreshDisconnectStatus()
        XCTAssertEqual(f.writes, [false])
        app.reconnectDisconnect()
        XCTAssertEqual(f.writes, [false, true])
        XCTAssertEqual(app.disconnectStatus?.resolved, false)
        XCTAssertTrue(app.disconnectStatus?.failure?.contains("fake reconnect") == true)
        let before = try Data(contentsOf: f.store.url)
        let relaunched = model(f)
        XCTAssertEqual(try Data(contentsOf: f.store.url), before)
        relaunched.reconnectDisconnect()
        XCTAssertEqual(f.writes, [false, true], "private enable is never replayed")
        XCTAssertEqual(try f.store.load().state, .needsAttention)
    }

    func testConfirmationRevalidatesIdentityAndUnresolvedJournalWithoutWrites() throws {
        let f = try fixture()
        f.fault = "identity"
        XCTAssertThrowsError(try f.controller.prepare(targetUUID: f.uuid))
        XCTAssertEqual(f.arms, 0)
        f.fault = ""

        // `requireClearJournal()` refuses a second disconnect while a journal
        // from a prior one (however it was started) is unresolved.
        try f.store.lock()
        try f.store.create(RecoveryJournal(snapshot: f.baseline))
        f.store.unlock()
        XCTAssertThrowsError(try f.controller.prepare(targetUUID: f.uuid)) {
            XCTAssertTrue($0.localizedDescription.contains("unresolved"))
        }
        XCTAssertEqual(f.arms, 0)
        XCTAssertEqual(try f.store.load().state, .captured)
        XCTAssertEqual(f.writes, [])
    }

    func testConfirmationKeepsConsentTimeIdentityBaseline() throws {
        for drift in [false, true] {
            let f = try fixture(drift ? "drift" : "unchanged")
            var controller = f.controller
            var writerConstructions = 0
            // Like production, construct a new preflight session from the
            // supplied snapshot, rather than fixing it to the fixture baseline.
            controller.preflight = { snapshot, target in
                let session = RecoveryPrivateSession(snapshot: snapshot, capture: { f.current }, inventory: {
                    RecoveryEnableInventory(bootSession: f.current.bootSession, osBuild: f.current.osBuild,
                        userID: f.current.userID, identities: f.current.displays.map(RecoveryEnableIdentity.init),
                        onlineIDs: Set(f.current.displays.map(\.id)), hostModel: f.current.hostModel,
                        architecture: "arm64", binding: .captureMatch)
                }, environment: { try f.session.environment() }, transaction: {
                    writerConstructions += 1
                    return try f.session.transaction()
                }, initiallyAwake: true)
                _ = try session.prepareDisable(targetID: target)
            }
            let request = try controller.prepare(targetUUID: f.uuid)
            XCTAssertEqual(writerConstructions, 1)
            if drift {
                var target = f.baseline.displays[1]
                target.identityEvidence?.transportLocation = "another-port"
                f.current = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
                    userID: f.baseline.userID, displays: [f.baseline.displays[0], target], hostModel: f.baseline.hostModel)
                try f.baseline.verify(f.current) // Public topology comparison alone misses this.
                XCTAssertThrowsError(try controller.disconnect(request, consent: true,
                    executable: URL(fileURLWithPath: "/unused"))) {
                    XCTAssertTrue($0.localizedDescription.contains("transport/location"))
                }
                XCTAssertEqual(writerConstructions, 1, "drift must refuse before writer construction")
                XCTAssertEqual(f.arms, 0, "drift must refuse before helper arming")
                XCTAssertEqual(f.writes, [])
            } else {
                let lease = try controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
                XCTAssertEqual(writerConstructions, 2)
                XCTAssertEqual(f.arms, 1)
                XCTAssertEqual(f.writes, [false])
                XCTAssertEqual(try f.store.load().snapshot, f.baseline)
                try lease.reconnect()
                XCTAssertEqual(f.writes, [false, true])
            }
        }
    }

    func testReconnectIgnoresExperimentalGateButRejectsChangedConsentJournal() async throws {
        let f = try fixture(), app = model(f)
        // A CLI-started disconnect journal appears; the app only observes it.
        let request = try f.controller.prepare(targetUUID: f.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        app.refreshDisconnectStatus()
        app.setExperimentalFeaturesEnabled(false)
        let journalID = try XCTUnwrap(app.disconnectStatus?.journalID)
        app.reconnectDisconnect(expectedJournalID: UUID().uuidString)
        XCTAssertEqual(f.writes, [false])
        XCTAssertTrue(app.disconnectFailure?.contains("journal changed") == true)
        app.reconnectDisconnect(expectedJournalID: journalID)
        XCTAssertEqual(f.writes, [false, true])
        XCTAssertEqual(app.disconnectStatus?.resolved, true)
    }

    func testWatchdogRecaptureRetainsQualifiedTransportAndHelperRefusesDrift() throws {
        let f = try fixture()
        var target = f.baseline.displays[1]
        target.identityEvidence?.transportLocation = "Port-USB-C@1/DisplayPort"
        let changed = RecoverySnapshot(bootSession: f.baseline.bootSession, osBuild: f.baseline.osBuild,
            userID: f.baseline.userID, displays: [f.baseline.displays[0], target], hostModel: f.baseline.hostModel)
        try f.baseline.verify(changed) // Public equality alone intentionally misses this drift.
        let executable = directory.appendingPathComponent("nonexistent-helper")
        // Run the real start/capture/journal boundary, but never a helper or writer.
        XCTAssertThrowsError(try RecoveryWatchdog.start(store: f.store, executable: executable,
            timeout: 15, verifyOnly: false, expectedSnapshot: f.baseline, privateLease: true,
            capture: { changed }))
        let retained = try f.store.load().snapshot
        XCTAssertEqual(retained, f.baseline)
        var writerConstructions = 0
        let session = RecoveryPrivateSession(snapshot: retained, capture: { changed }, inventory: {
            RecoveryEnableInventory(bootSession: changed.bootSession, osBuild: changed.osBuild,
                userID: changed.userID, identities: changed.displays.map(RecoveryEnableIdentity.init),
                onlineIDs: Set(changed.displays.map(\.id)), hostModel: changed.hostModel,
                architecture: "arm64", binding: .captureMatch)
        }, environment: {
            RecoveryEligibilityEnvironment(architecture: .appleSilicon, drivers: .nativeOnly,
                lid: .notApplicable, mirrored: false, screens: Dictionary(uniqueKeysWithValues: changed.displays.map {
                    ($0.id, .init(kind: .physical, online: true, active: true, awake: true))
                }))
        }, transaction: {
            writerConstructions += 1
            throw RecoveryError.unsafe("a writer must never be constructed")
        }, initiallyAwake: true)
        XCTAssertThrowsError(try session.prepareDisable(targetID: target.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("transport/location"), error.localizedDescription)
        }
        XCTAssertEqual(writerConstructions, 0)
    }

    func testNativeProductionControlsWithFakeStatusRender() async throws {
        try requireInteractiveUI()
        _ = NSApplication.shared
        let f = try fixture()
        func render(_ name: String, model renderingModel: AppModel) throws {
            let host = NSHostingView(rootView: Form {
                ExperimentalDisconnectControls(model: renderingModel)
            }.formStyle(.grouped))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let output = ProcessInfo.processInfo.environment["DISPLAYPANEL_DISCONNECT_FIXTURE_OUTPUT"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            }
        }
        // A CLI-started disconnect journal appears; the app only observes it.
        // Retain the lease; letting it deinit would reconnect immediately.
        let request = try f.controller.prepare(targetUUID: f.uuid)
        let lease = try f.controller.disconnect(request, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = lease
        let app = model(f)
        app.refreshDisplays()
        try render("integrated-lease", model: app)
        try f.finish?()
        app.refreshCountdown()
        XCTAssertEqual(app.disconnectStatus?.resolved, true)

        let unreadableFixture = try fixture("unreadable-ui")
        try Data("bad journal".utf8).write(to: unreadableFixture.store.url)
        let unreadableApp = model(unreadableFixture)
        try render("unreadable-recovery-paused", model: unreadableApp)
        await withCheckedContinuation { continuation in unreadableApp.shutdown { continuation.resume() } }

        let cleanupFixture = try fixture("cleanup-ui")
        let cleanupRequest = try cleanupFixture.controller.prepare(targetUUID: cleanupFixture.uuid)
        // Retain the lease; letting it deinit would reconnect immediately.
        let cleanupLease = try cleanupFixture.controller.disconnect(
            cleanupRequest, consent: true, executable: URL(fileURLWithPath: "/unused"))
        _ = cleanupLease
        var cleanupCompletion: ((Bool, String?) -> Void)?
        // Seeding the journal before construction means init's own
        // refreshDisconnectStatus() observes it and holds automation,
        // capturing the quiesce completion for this test to fire.
        let cleanupApp = model(cleanupFixture, quiesceProtection: { cleanupCompletion = $0 })
        cleanupCompletion?(false, "Synthetic saved-brightness cleanup failure")
        try await waitUntil { cleanupApp.protectionQuiescenceFailure != nil }
        try render("automation-cleanup-blocked", model: cleanupApp)
        await withCheckedContinuation { continuation in cleanupApp.shutdown { continuation.resume() } }
        await withCheckedContinuation { continuation in app.shutdown { continuation.resume() } }
    }
}
