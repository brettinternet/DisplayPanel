import XCTest
import CoreGraphics
import Darwin
@testable import PanelCtlCore

final class DisplayArrangementTests: XCTestCase {
    private var directory: URL!
    private var recoveryStore: RecoveryStore!
    private var operationStore: RecoveryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-arrangement-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        recoveryStore = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        operationStore = RecoveryStore(url: directory.appendingPathComponent("operation"))
    }

    override func tearDownWithError() throws {
        recoveryStore.unlock()
        operationStore.unlock()
        try FileManager.default.removeItem(at: directory)
    }

    private func member(_ index: Int, id: UInt32? = nil, x: Int32? = nil, y: Int32 = 0,
                        width: Double = 1920, height: Double = 1080, rotation: Double = 0,
                        main: Bool = false, name: String? = nil) -> DisplayArrangementMember {
        DisplayArrangementMember(
            uuid: String(format: "00000000-0000-0000-0000-%012d", index), id: id ?? UInt32(index),
            name: name ?? "Display \(index)", vendor: 100, model: UInt32(index), serial: UInt32(index + 10),
            x: x ?? (main ? 0 : Int32(index - 1) * 1920), y: y, width: width, height: height,
            rotation: rotation, main: main
        )
    }

    private func arrangement() -> DisplayArrangement {
        DisplayArrangement(members: [member(1, main: true), member(2)])
    }

    private func records(_ arrangement: DisplayArrangement, asleep: Set<UInt32> = []) -> [DisplayRecord] {
        arrangement.members.enumerated().map { index, display in
            DisplayRecord(index: index + 1, id: display.id, uuid: display.uuid, name: display.name,
                          active: true, online: true, asleep: asleep.contains(display.id), builtin: false,
                          main: display.main, vendor: display.vendor, model: display.model, serial: display.serial,
                          bounds: DisplayBounds(CGRect(x: Double(display.x), y: Double(display.y),
                                                       width: display.width, height: display.height)),
                          pixelWidth: Int(display.width), pixelHeight: Int(display.height))
        }
    }

    private func controller(records: @escaping () -> [DisplayRecord],
                            mirrorOf: @escaping (UInt32) -> UInt32 = { _ in kCGNullDirectDisplay },
                            rotation: @escaping (UInt32) -> Double = { _ in 0 },
                            transaction: DisplayArrangementTransaction = DisplayArrangementTransaction(),
                            convergencePause: @escaping () -> Void = {}) -> DisplayArrangementController {
        DisplayArrangementController(recoveryStore: recoveryStore, operationLock: { self.operationStore },
                                     records: records, mirrorOf: mirrorOf, rotation: rotation,
                                     transaction: transaction, convergencePause: convergencePause)
    }

    private func recoverySnapshot() throws -> RecoverySnapshot {
        let object: [String: Any] = [
            "bootSession": "arrangement-test-boot", "osBuild": "arrangement-test-build", "userID": getuid(),
            "displays": [[
                "uuid": member(1, main: true).uuid, "id": 1, "vendor": 100, "model": 1, "serial": 11,
                "builtin": false, "main": true, "active": true, "x": 0, "y": 0, "rotation": 0,
                "mode": ["id": 1, "width": 1920, "height": 1080, "pixelWidth": 1920,
                         "pixelHeight": 1080, "refreshRate": 60, "flags": 0]
            ]]
        ]
        return try JSONDecoder().decode(RecoverySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testSetKeyAndPlacementIgnoreOrderNamesAndNumericIDs() throws {
        let original = arrangement()
        var changed = DisplayArrangement(members: [original.members[1], original.members[0]])
        changed.members[0].name = "Renamed"
        changed.members[0].id = 99

        XCTAssertEqual(original.setKey, "\(member(1, main: true).uuid),\(member(2).uuid)")
        XCTAssertEqual(original.setKey, changed.setKey)
        XCTAssertTrue(original.samePlacement(as: changed))
        XCTAssertThrowsError(try DisplayArrangement(members: [original.members[0], original.members[0]]).validate())
        XCTAssertThrowsError(try DisplayArrangement(members: [member(1, x: 1, main: true), member(2)]).validate())
    }

    func testRestoringRebindsIDsAndRejectsAmbiguousOrChangedPhysicalIdentity() throws {
        let saved = DisplayArrangement(members: [member(1, id: 70, main: true), member(2, id: 71, x: 2400)])
        let current = DisplayArrangement(members: [member(1, id: 7, main: true), member(2, id: 8)])
        let restored = try current.restoring(saved)
        XCTAssertEqual(restored.members.map(\.id), [7, 8])
        XCTAssertEqual(restored.members.map(\.x), [0, 2400])

        var changedSize = saved
        changedSize.members[1].width = 1600
        XCTAssertThrowsError(try current.restoring(changedSize))
        var changedRotation = saved
        changedRotation.members[1].rotation = 90
        XCTAssertThrowsError(try current.restoring(changedRotation))

        var changedIdentity = saved
        changedIdentity.members[1].serial += 1
        XCTAssertThrowsError(try current.restoring(changedIdentity))
        let missing = DisplayArrangement(members: [saved.members[0]])
        XCTAssertThrowsError(try current.restoring(missing))
    }

    func testRememberedResolutionScaleAndRotationKeepMixedEdgesAndMain() throws {
        let saved = try DisplayArrangement(members: [
            member(1, width: 2000, height: 1200, main: true),
            member(2, x: 2000, y: 200, width: 1600, height: 1000), // bottom aligned
            member(3, x: -1000, width: 1000, height: 800), // top aligned
            member(4, x: 1500, y: -600, width: 500, height: 600), // right aligned above
            member(5, x: 250, y: 1200, width: 800, height: 600) // offset below
        ]).rememberingRelationships()
        XCTAssertEqual(saved.relationships?.map(\.side), [.right, .left, .above, .below])
        XCTAssertEqual(saved.relationships?.map(\.alignment), [.end, .start, .end, .offset])
        let decoded = try JSONDecoder().decode(DisplayArrangement.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        var current = saved
        current.members[0].width = 2400 // resolution
        current.members[0].height = 1350
        current.members[1].width = 800 // HiDPI logical size
        current.members[1].height = 500
        current.members[2].width = 800 // rotated bounds
        current.members[2].height = 1000
        current.members[2].rotation = 90
        current = try XCTUnwrap(current.preferringMain(current.members[1]))
        current.members.reverse()
        current.members[0].id = 99
        let restored = try current.restoringRemembered(decoded)
        let ordered = restored.members.sorted { $0.model < $1.model }
        XCTAssertEqual(ordered.map(\.x), [0, 2400, -800, 1900, 250])
        XCTAssertEqual(ordered.map(\.y), [0, 850, 0, -600, 1350])
        XCTAssertEqual(ordered.map(\.main), [true, false, false, false, false])
        XCTAssertEqual(ordered.map(\.width), [2400, 800, 800, 500, 800])
        XCTAssertEqual(ordered[2].rotation, 90)
        XCTAssertEqual(ordered[4].id, 99)
        XCTAssertThrowsError(try current.restoring(saved), "low-level restoration must remain strict")
    }

    func testLegacyRememberedLayoutsAdaptButUnchangedGeometryKeepsExactOrigins() throws {
        let original = arrangement()
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["relationships"], "legacy payload has only members")
        let legacy = try JSONDecoder().decode(DisplayArrangement.self, from: data)
        var current = original
        current.members[0].width = 2560
        XCTAssertEqual(try current.restoringRemembered(legacy).members[1].x, 2560)
        var unusual = original
        unusual.members[1].x = 2500
        unusual.members[1].y = -137
        let saved = try unusual.rememberingRelationships()
        XCTAssertNil(saved.relationships)
        XCTAssertEqual(try original.restoringRemembered(saved).members, unusual.members)
        XCTAssertThrowsError(try current.restoringRemembered(saved))
        var impostor = current
        impostor.members[1].serial += 1
        XCTAssertThrowsError(try impostor.restoringRemembered(legacy))
        var corrupted = try original.rememberingRelationships()
        corrupted.relationships?[0].side = .left
        XCTAssertThrowsError(try current.restoringRemembered(corrupted))
    }

    func testResizedLayoutsRefuseOverlapLostContactAndUnrepresentableOrigins() throws {
        let branching = try DisplayArrangement(members: [
            member(1, width: 1000, height: 1000, main: true),
            member(2, x: 1000, width: 500, height: 500),
            member(3, x: 1000, y: 500, width: 500, height: 500)
        ]).rememberingRelationships()
        var current = branching
        current.members[1].height = 800
        XCTAssertThrowsError(try current.restoringRemembered(branching)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlap"))
        }
        let offset = try DisplayArrangement(members: [
            member(1, width: 1000, height: 1000, main: true),
            member(2, x: 1000, y: 800, width: 500, height: 500)
        ]).rememberingRelationships()
        current = offset
        current.members[0].height = 700
        XCTAssertThrowsError(try current.restoringRemembered(offset)) { error in
            XCTAssertTrue(error.localizedDescription.contains("shared edge"))
        }
        for width in [Double(Int32.max) + 1, 1920.5] {
            current = arrangement()
            current.members[0].width = width
            XCTAssertThrowsError(try current.restoringRemembered(arrangement())) { error in
                XCTAssertTrue(error.localizedDescription.contains("unrepresentable"))
            }
        }
    }

    func testAdaptedLayoutUsesStrictFakeWriterAndRefusesModeRace() throws {
        let saved = try arrangement().rememberingRelationships()
        var current = arrangement()
        current.members[0].width = 2560
        let expected = current
        let desired = try current.restoringRemembered(saved)
        var staged: [UInt32: Int32] = [:]
        var completes = 0, cancels = 0
        var race = false
        let transaction = DisplayArrangementTransaction(
            begin: { CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, id, x, _ in
                staged[id] = x
                if race { current.members[0].width = 3000 }
            },
            complete: { _, scope in
                XCTAssertEqual(scope, .forSession)
                completes += 1
                current = desired
            },
            cancel: { _ in cancels += 1 }
        )
        let sut = controller(records: { self.records(current) }, transaction: transaction)
        XCTAssertTrue(try sut.restore(desired, expected: expected))
        XCTAssertEqual(staged[2], 2560)
        XCTAssertEqual(completes, 1)
        current = expected
        race = true
        XCTAssertThrowsError(try sut.restore(desired, expected: expected))
        XCTAssertEqual(completes, 1, "geometry races cannot complete a transaction")
        XCTAssertEqual(cancels, 1)
    }

    func testPreferringMainTranslatesEveryOriginAndValidatesMetadata() throws {
        let base = DisplayArrangement(members: [
            member(1, main: true), member(2, x: 1920), member(3, x: 1920, y: 1080)
        ])
        let preferred = try XCTUnwrap(base.preferringMain(base.members[2]))
        XCTAssertEqual(preferred.members.map(\.x), [-1920, 0, 0])
        XCTAssertEqual(preferred.members.map(\.y), [-1080, -1080, 0])
        XCTAssertEqual(preferred.members.map(\.main), [false, false, true])
        XCTAssertEqual(preferred.members[1].x - preferred.members[0].x, 1920)

        var staleGeometry = base.members[2]
        staleGeometry.width = 1600
        staleGeometry.height = 900
        staleGeometry.rotation = 90
        let acceptedPreference = try XCTUnwrap(base.preferringMain(staleGeometry))
        XCTAssertEqual(acceptedPreference.members.map(\.width), base.members.map(\.width))
        XCTAssertEqual(acceptedPreference.members.map(\.height), base.members.map(\.height))
        XCTAssertEqual(acceptedPreference.members.map(\.rotation), base.members.map(\.rotation))

        var staleIdentity = base.members[2]
        staleIdentity.vendor += 1
        XCTAssertThrowsError(try base.preferringMain(staleIdentity))
        XCTAssertNil(try base.preferringMain(member(4)))

        var edge = DisplayArrangement(members: [member(1, main: true), member(2, x: .max), member(3, x: .min)])
        edge.members[1].main = false
        XCTAssertThrowsError(try edge.preferringMain(edge.members[1]))
    }

    func testCaptureRejectsWholeInventoryAmbiguityMirrorsSleepAndHiddenMain() throws {
        let base = arrangement()
        XCTAssertNoThrow(try controller(records: { self.records(base) }).capture(excluding: [member(2).uuid]))
        XCTAssertThrowsError(try controller(records: {
            var duplicates = self.records(base)
            duplicates[1] = DisplayRecord(index: 2, id: 2, uuid: self.member(1, main: true).uuid, name: nil,
                active: true, online: true, asleep: false, builtin: false, main: false,
                vendor: 100, model: 2, serial: 12, bounds: DisplayBounds(CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
                pixelWidth: 1920, pixelHeight: 1080)
            return duplicates
        }).capture())
        XCTAssertThrowsError(try controller(records: { self.records(base) },
                                            mirrorOf: { $0 == 2 ? 1 : kCGNullDirectDisplay })
            .capture(excluding: [member(2).uuid]))
        XCTAssertThrowsError(try controller(records: { self.records(base, asleep: [2]) })
            .capture(excluding: [member(2).uuid]))
        XCTAssertThrowsError(try controller(records: { self.records(base) })
            .capture(excluding: [member(1, main: true).uuid]))
    }

    func testRestoreUsesSessionOriginsMainLastAndVerifiesOnce() throws {
        var current = arrangement()
        let expected = current
        let desired = DisplayArrangement(members: [member(1, x: -1920, main: false), member(2, x: 0, main: true)])
        var origins: [(UInt32, Int32, Int32)] = []
        var begins = 0, completes = 0, cancels = 0
        let transaction = DisplayArrangementTransaction(
            begin: { begins += 1; return CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, id, x, y in origins.append((id, x, y)) },
            complete: { _, scope in
                XCTAssertEqual(scope, .forSession)
                completes += 1
                current = desired
            },
            cancel: { _ in cancels += 1 }
        )
        let sut = controller(records: { self.records(current) },
                             rotation: { id in current.members.first(where: { $0.id == id })?.rotation ?? 0 },
                             transaction: transaction)

        XCTAssertTrue(try sut.restore(desired, expected: expected))
        XCTAssertEqual(origins.map(\.0), [1, 2], "non-main origins stage before the main origin")
        XCTAssertEqual(origins.map(\.1), [-1920, 0])
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(completes, 1)
        XCTAssertEqual(cancels, 0)
        XCTAssertTrue(current.samePlacement(as: desired))
    }

    func testExcludedDisplaysTranslateWithMainShiftAndRemainInBoundaryChecks() throws {
        let fullBaseline = DisplayArrangement(members: [member(1, main: true), member(2), member(3)])
        let expected = DisplayArrangement(members: Array(fullBaseline.members.prefix(2)))
        let desired = DisplayArrangement(members: [member(1, x: -1920), member(2, x: 0, main: true)])
        let fullDesired = DisplayArrangement(members: [
            member(1, x: -1920), member(2, x: 0, main: true), member(3, x: 1920)
        ])
        var current = fullBaseline
        var stagedIDs: [UInt32] = []
        var completes = 0
        let transaction = DisplayArrangementTransaction(
            begin: { CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, id, _, _ in stagedIDs.append(id) },
            complete: { _, _ in completes += 1; current = fullDesired },
            cancel: { _ in XCTFail("successful fake transaction must not be cancelled") }
        )
        let sut = controller(records: { self.records(current) },
                             rotation: { id in current.members.first(where: { $0.id == id })?.rotation ?? 0 },
                             transaction: transaction)

        XCTAssertTrue(try sut.restore(desired, expected: expected, excluding: [member(3).uuid]))
        XCTAssertEqual(stagedIDs, [1, 3, 2], "excluded displays move with the old-main translation; main stages last")
        XCTAssertEqual(current, fullDesired)
        XCTAssertEqual(completes, 1)

        current = fullBaseline
        var changedExcludedDuringStage = false
        var raceCompletes = 0, cancels = 0
        let raceTransaction = DisplayArrangementTransaction(
            begin: { CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, _, _, _ in
                if !changedExcludedDuringStage {
                    changedExcludedDuringStage = true
                    current.members[2].x += 100
                }
            },
            complete: { _, _ in raceCompletes += 1 },
            cancel: { _ in cancels += 1 }
        )
        let raceController = controller(records: { self.records(current) },
                                        rotation: { id in current.members.first(where: { $0.id == id })?.rotation ?? 0 },
                                        transaction: raceTransaction)
        XCTAssertThrowsError(try raceController.restore(desired, expected: expected, excluding: [member(3).uuid]))
        XCTAssertEqual(raceCompletes, 0, "a race affecting only an excluded display cancels before completion")
        XCTAssertEqual(cancels, 1)
    }

    func testRestoreRefusesUnresolvedJournalAndBothLocksBeforeWriter() throws {
        let current = arrangement()
        let desired = DisplayArrangement(members: [member(1, main: true), member(2, x: 2200)])
        var begins = 0
        let transaction = DisplayArrangementTransaction(begin: {
            begins += 1
            return CGDisplayConfigRef(bitPattern: 1)!
        })
        let sut = controller(records: { self.records(current) }, transaction: transaction)

        try recoveryStore.lock()
        try recoveryStore.create(RecoveryJournal(snapshot: recoverySnapshot()))
        recoveryStore.unlock()
        XCTAssertThrowsError(try sut.restore(desired, expected: current))
        XCTAssertEqual(begins, 0)

        let clearStore = RecoveryStore(url: directory.appendingPathComponent("clear.json"))
        let clearController = DisplayArrangementController(recoveryStore: clearStore,
            operationLock: { self.operationStore }, records: { self.records(current) },
            transaction: transaction)
        try operationStore.lock()
        XCTAssertThrowsError(try clearController.restore(desired, expected: current))
        operationStore.unlock()
        XCTAssertEqual(begins, 0)

        try clearStore.lock()
        XCTAssertThrowsError(try clearController.restore(desired, expected: current))
        clearStore.unlock()
        XCTAssertEqual(begins, 0)
    }

    func testRestoreRevalidatesTopologyAndNumericIDsAtWriterBoundaries() throws {
        var current = arrangement()
        let expected = current
        let desired = DisplayArrangement(members: [member(1, main: true), member(2, x: 2200)])
        var begins = 0, completes = 0, cancels = 0
        let transaction = DisplayArrangementTransaction(
            begin: { begins += 1; return CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, _, _, _ in current.members[1].x = 2100 },
            complete: { _, _ in completes += 1 },
            cancel: { _ in cancels += 1 }
        )
        let sut = controller(records: { self.records(current) },
                             rotation: { id in current.members.first(where: { $0.id == id })?.rotation ?? 0 },
                             transaction: transaction)
        XCTAssertThrowsError(try sut.restore(desired, expected: expected))
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(completes, 0)
        XCTAssertEqual(cancels, 1)

        current = expected
        current.members[1].id = 88
        XCTAssertTrue(expected.samePlacement(as: current), "numeric IDs are checked separately from placement")
        XCTAssertThrowsError(try sut.restore(desired, expected: expected))
        XCTAssertEqual(begins, 1, "a numeric-ID rebind is refused before beginning a transaction")
    }

    func testFailedVerificationUsesSixSamplesAndNeverRetriesWriter() throws {
        let current = arrangement()
        let desired = DisplayArrangement(members: [member(1, main: true), member(2, x: 2200)])
        var stagedIDs: [UInt32] = [], completes = 0, pauses = 0
        let transaction = DisplayArrangementTransaction(
            begin: { CGDisplayConfigRef(bitPattern: 1)! },
            origin: { _, id, _, _ in stagedIDs.append(id) },
            complete: { _, _ in completes += 1 },
            cancel: { _ in XCTFail("consumed transaction must not be cancelled") }
        )
        let sut = controller(records: { self.records(current) }, transaction: transaction,
                             convergencePause: { pauses += 1 })
        XCTAssertThrowsError(try sut.restore(desired, expected: current))
        XCTAssertEqual(stagedIDs, [2, 1], "the main origin is always staged last for any write")
        XCTAssertEqual(completes, 1)
        XCTAssertEqual(pauses, 5)
    }

    private func mode(rate: Double) throws -> RecoveryMode {
        try JSONDecoder().decode(RecoveryMode.self, from: JSONSerialization.data(withJSONObject: [
            "id": 7, "width": 1920, "height": 1080, "pixelWidth": 3840,
            "pixelHeight": 2160, "refreshRate": rate, "flags": 0
        ]))
    }

    private func modeController(_ layout: @escaping () -> DisplayArrangement,
                                current: @escaping () throws -> RecoveryMode,
                                offered: @escaping () -> [RecoveryMode],
                                transaction: DisplayModeTransaction) -> DisplayModeProtectionController {
        var controller = DisplayModeProtectionController()
        controller.recoveryStore = recoveryStore
        controller.operationLock = { self.operationStore }
        controller.records = { self.records(layout()) }
        controller.mirrored = { _ in false }
        controller.rotation = { _ in 0 }
        controller.currentMode = { _ in try current() }
        controller.availableModes = { _ in offered() }
        controller.transaction = transaction
        controller.convergencePause = {}
        return controller
    }

    func testModeRestoreExactSessionCommitRebindsAddressAndVerifiesWithoutRetry() throws {
        var layout = arrangement()
        let high = try mode(rate: 240), low = try mode(rate: 60)
        let saved = SavedDisplayMode(display: records(layout)[0], mode: high)
        layout.members[0].id = 81
        var current = low
        var commits = 0
        var verifySuccess = true
        let transaction = DisplayModeTransaction(
            begin: { CGDisplayConfigRef(bitPattern: 1)! },
            prepare: { id, mode in
                XCTAssertEqual(id, 81)
                XCTAssertEqual(mode, high)
                return { _ in }
            }, complete: { _, option in
                XCTAssertEqual(option, .forSession)
                commits += 1
                if verifySuccess { current = high }
            }, cancel: { _ in XCTFail("completed transactions must not cancel") })
        let sut = modeController({ layout }, current: { current }, offered: { [low, high] }, transaction: transaction)
        XCTAssertTrue(try sut.restore(saved))
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(try sut.restore(saved))
        current = low
        verifySuccess = false
        XCTAssertThrowsError(try sut.restore(saved)) { XCTAssertTrue($0.localizedDescription.contains("did not verify")) }
        XCTAssertEqual(commits, 2, "verification retries must not write again")
    }

    func testModeRestoreRejectsMissingExactModeIdentityMirrorsJournalsAndLocks() throws {
        var layout = arrangement()
        let high = try mode(rate: 240), low = try mode(rate: 60)
        let saved = SavedDisplayMode(display: records(layout)[0], mode: high)
        var offered = [low]
        var begins = 0
        var sut = modeController({ layout }, current: { low }, offered: { offered }, transaction: DisplayModeTransaction(
            begin: { begins += 1; throw RecoveryError.unsafe("unexpected write") }, prepare: { _, _ in { _ in } }))
        XCTAssertThrowsError(try sut.restore(saved)) { XCTAssertTrue($0.localizedDescription.contains("unavailable")) }
        offered = [high]
        layout.members[0].serial += 1
        XCTAssertThrowsError(try sut.restore(saved))
        layout = arrangement()
        layout.members.append(layout.members[0])
        XCTAssertThrowsError(try sut.restore(saved))
        layout = arrangement()
        sut.mirrored = { _ in true }
        XCTAssertThrowsError(try sut.restore(saved))
        sut.mirrored = { _ in false }
        try operationStore.lock()
        XCTAssertThrowsError(try sut.restore(saved))
        operationStore.unlock()
        try recoveryStore.lock()
        XCTAssertThrowsError(try sut.restore(saved))
        try recoveryStore.create(RecoveryJournal(snapshot: recoverySnapshot()))
        recoveryStore.unlock()
        XCTAssertThrowsError(try sut.restore(saved))
        XCTAssertEqual(begins, 0)
    }

    func testModeRestoreCancelsTopologyAndIdentityRacesAtCommitBoundary() throws {
        for mutation in ["topology", "identity", "mode"] {
            var layout = arrangement()
            let high = try mode(rate: 240), low = try mode(rate: 60)
            let saved = SavedDisplayMode(display: records(layout)[0], mode: high)
            var current = low
            var commits = 0, cancels = 0
            let transaction = DisplayModeTransaction(
                begin: { CGDisplayConfigRef(bitPattern: 1)! }, prepare: { _, _ in { _ in
                    if mutation == "topology" { layout.members[1].x += 10 }
                    if mutation == "identity" { layout.members[0].id = 88 }
                    if mutation == "mode" { current = high }
                } }, complete: { _, _ in commits += 1 }, cancel: { _ in cancels += 1 })
            let sut = modeController({ layout }, current: { current }, offered: { [low, high] }, transaction: transaction)
            XCTAssertThrowsError(try sut.restore(saved), mutation)
            XCTAssertEqual(commits, 0, mutation)
            XCTAssertEqual(cancels, 1, mutation)
        }
    }

    func testNoOpRestoreDoesNotOpenWriter() throws {
        let current = arrangement()
        let sut = controller(records: { self.records(current) }, transaction: DisplayArrangementTransaction(
            begin: { XCTFail("no-op must not begin a transaction"); return CGDisplayConfigRef(bitPattern: 1)! }
        ))
        XCTAssertFalse(try sut.restore(current, expected: current))
    }
}
