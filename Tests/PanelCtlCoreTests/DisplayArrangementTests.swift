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

    func testNoOpRestoreDoesNotOpenWriter() throws {
        let current = arrangement()
        let sut = controller(records: { self.records(current) }, transaction: DisplayArrangementTransaction(
            begin: { XCTFail("no-op must not begin a transaction"); return CGDisplayConfigRef(bitPattern: 1)! }
        ))
        XCTAssertFalse(try sut.restore(current, expected: current))
    }
}
