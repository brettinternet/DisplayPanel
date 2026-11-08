import XCTest
import CoreGraphics
import Darwin
@testable import DisplayPanelCore

/// Turn off with fake writers only; no test can reach the private setter.
final class DisplayTurnOffTests: XCTestCase {
    private var directory: URL!
    private var store: RecoveryStore!
    private var world: World!

    override func setUpWithError() throws {
        directory = try makeTestDirectory()
        store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        world = World()
    }

    override func tearDownWithError() throws {
        store.unlock()
    }

    /// Three external displays in a row; display 1 is main. Turned-off
    /// displays vanish; a mirrored display follows its source.
    private final class World {
        var off: Set<Int> = []
        var mirrors: [Int: Int] = [:]
        var mainOverride: Int?
        var order: [Int]?
        var builtin: Set<Int> = []
        var bootSession = "test-boot"
        var writes: [String] = []
        var applies = 0
        var returns = true
        var commitError: String?
        var duringStage: () throws -> Void = {}
        var environment: (inout RecoveryEligibilityEnvironment) -> Void = { _ in }
        var transactionAvailable = true
        /// macOS applies its saved layout for the remaining displays on turn-off.
        var onTurnOff: (World) -> Void = { _ in }

        func id(_ index: Int) -> UInt32 { UInt32(index + 6) }
        func uuid(_ index: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", index) }
        func index(_ id: UInt32) -> Int { Int(id) - 6 }

        func snapshot(private includePrivate: Bool = false) throws -> RecoverySnapshot {
            let present = (1...3).filter { !off.contains($0) }
            let visible = present.filter { mirrors[$0] == nil }
            let main = mainOverride.flatMap { visible.contains($0) ? $0 : nil } ??
                (visible.contains(1) ? 1 : visible.first ?? 0)
            let ordered = [main] + (order ?? visible).filter { $0 != main && visible.contains($0) }
            func x(_ index: Int) -> Int { (ordered.firstIndex(of: mirrors[index] ?? index) ?? 0) * 1920 }
            let displays: [[String: Any]] = present.map { index in
                var display: [String: Any] = [
                    "uuid": uuid(index), "id": id(index), "vendor": 1, "model": index, "serial": index,
                    "builtin": builtin.contains(index), "main": index == main, "active": mirrors[index] == nil,
                    "x": x(index), "y": 0, "rotation": 0,
                    "mode": ["id": index, "width": 1920, "height": 1080, "pixelWidth": 1920,
                             "pixelHeight": 1080, "refreshRate": 60, "flags": 0]
                ]
                if let source = mirrors[index] { display["mirrorUUID"] = uuid(source) }
                if includePrivate {
                    display["connector"] = "port-\(index)"
                    display["identityEvidence"] = ["source": "syntheticFixture", "capturedAt": 0,
                                                   "transport": "DisplayPort", "transportLocation": "loc-\(index)"]
                }
                return display
            }
            let value: [String: Any] = ["bootSession": bootSession, "osBuild": "test-build", "userID": getuid(),
                                        "hostModel": "Mac-Test", "displays": displays]
            return try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }

        func records() throws -> [DisplayRecord] {
            try snapshot().displays.enumerated().map { offset, display in
                DisplayRecord(index: offset + 1, id: display.id, uuid: display.uuid, name: "Display \(index(display.id))",
                              active: display.active, online: true, asleep: false, builtin: display.builtin,
                              main: display.main, vendor: display.vendor, model: display.model, serial: display.serial,
                              bounds: DisplayBounds(CGRect(x: Int(display.x), y: 0, width: 1920, height: 1080)),
                              pixelWidth: 1920, pixelHeight: 1080)
            }
        }

        func identity(_ index: Int) throws -> DisplayHideIdentity {
            let display = try XCTUnwrap(snapshot().displays.first { $0.uuid == uuid(index) })
            return DisplayHideIdentity(uuid: display.uuid, displayID: display.id, name: "Display \(index)",
                                       vendor: display.vendor, model: display.model, serial: display.serial)
        }

        var backend: DisplayTurnOffBackend {
            DisplayTurnOffBackend(
                capture: { try self.snapshot(private: true) },
                inventory: { saved in
                    let online = try self.snapshot()
                    return RecoveryEnableInventory(
                        bootSession: online.bootSession, osBuild: online.osBuild, userID: online.userID,
                        identities: saved.displays.map { display in
                            guard self.off.contains(self.index(display.id)) else { return RecoveryEnableIdentity(display) }
                            return RecoveryEnableIdentity(uuid: nil, id: display.id, vendor: display.vendor,
                                model: display.model, serial: display.serial, builtin: display.builtin,
                                connector: display.connector ?? "", transport: "DisplayPort", framebufferLocation: nil,
                                transportLocation: display.identityEvidence?.transportLocation)
                        },
                        onlineIDs: Set(online.displays.map(\.id)), hostModel: "Mac-Test",
                        architecture: "synthetic", binding: .syntheticPhysicalFixture)
                },
                environment: { capture in
                    var environment = RecoveryEligibilityEnvironment(
                        architecture: .appleSilicon, drivers: .nativeOnly, lid: .notApplicable, mirrored: false,
                        screens: Dictionary(uniqueKeysWithValues: capture.displays.map {
                            ($0.id, .init(kind: .physical, online: true, active: $0.active, awake: true))
                        }))
                    self.environment(&environment)
                    return environment
                },
                awake: { true },
                transaction: {
                    guard self.transactionAvailable else { throw RecoveryError.unsafe("unrecognized setter") }
                    var staged: (UInt32, Bool)?
                    return RecoveryEnableTransaction(begin: { CGDisplayConfigRef(bitPattern: 1)! }, setEnabled: { _, id, enabled in
                        staged = (id, enabled)
                        try self.duringStage()
                    }, commit: { _, scope in
                        XCTAssertEqual(scope, .forSession)
                        let (id, enabled) = try XCTUnwrap(staged)
                        self.writes.append("\(enabled ? "on" : "off") \(id)")
                        if !enabled {
                            self.off.insert(self.index(id))
                            self.onTurnOff(self)
                        } else if self.returns {
                            self.off.remove(self.index(id))
                            // macOS returns a display beside the others, not as main.
                            self.mainOverride = (1...3).first { !self.off.contains($0) && $0 != self.index(id) }
                        }
                        if let error = self.commitError { throw RecoveryError.unsafe(error) }
                    }, cancel: { _ in self.writes.append("cancel") })
                }
            )
        }

        func controller(directory: URL) -> MirrorController {
            var staged: (UInt32, UInt32)?
            var origins: [(Int, Int32)] = []
            let operation = RecoveryStore(url: directory.appendingPathComponent("operation"))
            var controller = MirrorController(
                records: { try self.records() }, operationLock: { operation },
                engine: RecoveryEngine(capture: { try self.snapshot() }, apply: { _ in
                    self.applies += 1
                    self.mirrors = [:]
                    self.mainOverride = nil
                    self.order = nil
                }, convergencePause: {}),
                preflightModes: { _ in },
                transaction: MirrorTransaction(
                    begin: { OpaquePointer(bitPattern: 1)! },
                    stage: { _, target, source in staged = (target, source) },
                    complete: { _, _ in
                        if let (target, source) = staged { self.mirrors[self.index(target)] = self.index(source) }
                        if !origins.isEmpty {
                            self.writes.append("origins")
                            self.mainOverride = origins.first { $0.1 == 0 }?.0
                            self.order = origins.sorted { $0.1 < $1.1 }.map(\.0)
                        }
                        staged = nil
                        origins = []
                    }, cancel: { _ in XCTFail("fake public writer has no rollback") },
                    stageOrigin: { _, id, x, _ in origins.append((self.index(id), x)) }),
                restoreTarget: { _, uuid, revalidate, _ in
                    try revalidate()
                    let index = try XCTUnwrap((1...3).first { self.uuid($0) == uuid })
                    self.mirrors.removeValue(forKey: index)
                    if self.mainOverride != nil, index == 1 { self.mainOverride = nil }
                }
            )
            controller.turnOffBackend = backend
            return controller
        }
    }

    private func disconnect(_ index: Int) throws -> SessionDisconnect {
        try XCTUnwrap(store.load().publicMirrorSession?.disconnects?.last { $0.targetUUID == world.uuid(index) })
    }

    func testTurnOffJournalsBeforeEachWriteAndShowReconnectsTheSavedMainOnce() throws {
        let baseline = try world.snapshot()
        let sut = world.controller(directory: directory)
        world.duringStage = {
            let saved = try self.store.load()
            let entry = try XCTUnwrap(saved.publicMirrorSession?.disconnects?.last)
            XCTAssertEqual(entry.targetID, 7)
            if self.world.writes.isEmpty {
                XCTAssertEqual(entry.state, .turningOff)
                XCTAssertEqual(saved.state, .captured)
                XCTAssertEqual(saved.publicMirrorSession?.baseline, baseline)
            } else {
                XCTAssertEqual(entry.state, .reconnecting)
                XCTAssertEqual(saved.state, .restoring)
            }
        }

        _ = try sut.turnOff(world.identity(1), store: store)
        XCTAssertEqual(world.writes, ["off 7"])
        XCTAssertEqual(try disconnect(1).state, .off)
        XCTAssertEqual(try store.load().state, .mirrored)
        XCTAssertTrue(try world.snapshot().displays.first { $0.uuid == world.uuid(2) }?.main == true)
        XCTAssertNoThrow(try store.load().validate())

        let shown = try sut.unmirror(store: store, selector: world.uuid(1))
        XCTAssertEqual(world.writes, ["off 7", "on 7"])
        XCTAssertEqual(world.applies, 1, "the returned display gets its main role back")
        XCTAssertEqual(try world.snapshot(), baseline)
        XCTAssertEqual(shown.state, .restored)
        XCTAssertEqual(try disconnect(1).state, .restored)

        // Show again is a no-op; the reconnect is never repeated.
        _ = try sut.unmirror(store: store, selector: world.uuid(1))
        XCTAssertEqual(world.writes, ["off 7", "on 7"])
    }

    func testRefusalsWriteNothingAndAFailedRevalidationCancelsTheIntent() throws {
        let cases: [(String, (World) -> Void)] = [
            ("built-in", { $0.builtin = [2] }),
            ("mirrored", { $0.mirrors[2] = 1 }),
            ("mirror source", { $0.mirrors[3] = 2 }),
            ("no usable survivor", { world in world.environment = { env in
                for id in env.screens.keys where id != 8 { env.screens[id]?.kind = .virtual }
            } }),
            ("DisplayLink", { world in world.environment = { $0.drivers = .displayLink } }),
            ("unknown peer", { world in world.environment = { $0.screens[9]?.kind = .unknown } }),
            ("unrecognized setter", { $0.transactionAvailable = false })
        ]
        for (name, setUp) in cases {
            world = World()
            setUp(world)
            let caseStore = RecoveryStore(url: directory.appendingPathComponent("\(name).json"))
            let sut = world.controller(directory: directory)
            XCTAssertThrowsError(try sut.turnOff(world.identity(2), store: caseStore), name)
            XCTAssertFalse(try caseStore.exists(), name)
            XCTAssertEqual(world.writes, [], name)
        }

        world = World()
        let sut = world.controller(directory: directory)
        world.duringStage = { self.world.mirrors[3] = 1 }
        XCTAssertThrowsError(try sut.turnOff(world.identity(2), store: store))
        XCTAssertEqual(world.writes, ["cancel"])
        XCTAssertEqual(try disconnect(2).state, .cancelled)
        XCTAssertTrue(try store.load().state.resolved)

        // A crash before commit leaves `turningOff` with the display still on;
        // a layout change before the next inspection mustn't strand the journal.
        world = World()
        let crashSUT = world.controller(directory: directory)
        var crashed: RecoveryJournal?
        world.duringStage = { crashed = try self.store.load(); throw RecoveryError.unsafe("crash") }
        XCTAssertThrowsError(try crashSUT.turnOff(world.identity(2), store: store))
        try store.lock()
        try store.save(XCTUnwrap(crashed))
        store.unlock()
        world.duringStage = {}
        world.order = [1, 3, 2]
        let hide = DisplayHideController(store: store, mirror: crashSUT,
                                         operationLock: { RecoveryStore(url: self.directory.appendingPathComponent("operation")) })
        _ = try hide.inspect()
        XCTAssertTrue(try store.load().state.resolved)
        XCTAssertNoThrow(try crashSUT.turnOff(world.identity(2), store: store))
        XCTAssertEqual(world.writes, ["cancel", "off 8"])
    }

    func testSiblingHideAndShowWhileTheMainDisplayIsTurnedOff() throws {
        let baseline = try world.snapshot()
        let sut = world.controller(directory: directory)
        _ = try sut.turnOff(world.identity(1), store: store)
        XCTAssertThrowsError(try sut.turnOff(world.identity(3), store: store), "one Turn off at a time")

        _ = try sut.mirror(selector: world.uuid(3), source: world.uuid(2), store: store)
        XCTAssertEqual(world.mirrors, [3: 2])
        _ = try sut.unmirror(store: store, selector: world.uuid(3))
        XCTAssertEqual(world.mirrors, [:])
        XCTAssertEqual(try store.load().state, .mirrored, "display 1 is still off")
        XCTAssertEqual(world.writes, ["off 7"])

        _ = try sut.unmirror(store: store, selector: world.uuid(1))
        XCTAssertEqual(world.writes, ["off 7", "on 7"])
        XCTAssertEqual(try world.snapshot(), baseline)
        XCTAssertEqual(try store.load().state, .restored)
    }

    func testReconnectIsNeverRetriedAndAReturnedDisplayIsShownPublicly() throws {
        let baseline = try world.snapshot()
        let sut = world.controller(directory: directory)
        _ = try sut.turnOff(world.identity(2), store: store)

        world.returns = false
        world.commitError = "completion failed"
        XCTAssertThrowsError(try sut.unmirror(store: store, selector: world.uuid(2))) { error in
            XCTAssertTrue("\(error)".contains(DisplayTurnOff.didNotReturn))
        }
        XCTAssertEqual(try disconnect(2).state, .needsAttention)
        XCTAssertEqual(try store.load().state, .needsAttention)
        XCTAssertThrowsError(try sut.unmirror(store: store, selector: world.uuid(2)))
        XCTAssertEqual(world.writes, ["off 8", "on 8"])

        // The user selects the Mac's input; Show puts it back without a private write.
        world.off.remove(2)
        world.order = [1, 3, 2]
        _ = try sut.unmirror(store: store, selector: world.uuid(2))
        XCTAssertEqual(world.writes, ["off 8", "on 8"])
        XCTAssertEqual(world.applies, 1)
        XCTAssertEqual(try world.snapshot(), baseline)
        XCTAssertEqual(try store.load().state, .restored)
    }

    /// Regression (26B123 trial): macOS applied its saved layout for the other
    /// displays, making another one main; Turn off reported a false failure.
    func testTurnOffGivesMainBackWhenMacOSMovesIt() throws {
        let baseline = try world.snapshot()
        let sut = world.controller(directory: directory)
        world.onTurnOff = { $0.mainOverride = 3 }
        _ = try sut.turnOff(world.identity(2), store: store)
        XCTAssertEqual(world.writes, ["off 8", "origins"])
        XCTAssertEqual(try disconnect(2).state, .off)
        XCTAssertNil(try disconnect(2).failure)
        XCTAssertEqual(try store.load().state, .mirrored)
        XCTAssertEqual(try world.snapshot().displays.first(where: \.main)?.uuid, world.uuid(1))

        _ = try sut.unmirror(store: store, selector: world.uuid(2))
        XCTAssertEqual(world.writes, ["off 8", "origins", "on 8"])
        XCTAssertEqual(try world.snapshot(), baseline)
        XCTAssertEqual(try store.load().state, .restored)
    }

    /// Regression (26B123 trial): macOS dropped a Hide mirror when another
    /// display turned off, and the app refused the Show that reconnects it.
    func testShowReconnectsAfterMacOSDropsAHideMirror() throws {
        let sut = world.controller(directory: directory)
        _ = try sut.mirror(selector: world.uuid(3), source: world.uuid(2), store: store)
        world.onTurnOff = { $0.mirrors = [:] }
        XCTAssertThrowsError(try sut.turnOff(world.identity(1), store: store))
        XCTAssertEqual(try disconnect(1).state, .off)

        let hide = DisplayHideController(store: store, mirror: sut,
                                         operationLock: { RecoveryStore(url: self.directory.appendingPathComponent("operation")) })
        XCTAssertEqual(try hide.inspect().turnedOff.first?.canShow, true)
        _ = try? sut.unmirror(store: store, selector: world.uuid(1))
        XCTAssertEqual(world.writes, ["off 7", "on 7"])
        XCTAssertEqual(world.off, [])
    }

    func testRelaunchAndSystemReconnectNeverTurnOffAgain() throws {
        let sut = world.controller(directory: directory)
        _ = try sut.turnOff(world.identity(2), store: store)
        let hide = DisplayHideController(store: store, mirror: sut,
                                         operationLock: { RecoveryStore(url: self.directory.appendingPathComponent("operation")) })
        var status = try hide.inspect()
        XCTAssertEqual(status.turnedOff.map(\.state), ["off"])
        XCTAssertEqual(status.turnedOff.first?.canShow, true)

        // macOS reconnects it elsewhere (replug or new login): kept until Show, never re-disabled.
        world.off.remove(2)
        world.order = [1, 3, 2]
        status = try hide.inspect()
        XCTAssertEqual(status.turnedOff.map(\.state), ["off"])
        XCTAssertEqual(status.turnedOff.first?.canShow, true)
        XCTAssertEqual(world.writes, ["off 8"])

        // After a restart the old journal is retired; Hide again never turns a display off.
        world.bootSession = "next-boot"
        let recovery = try XCTUnwrap(sut.sessionRecovery(journal: store.load(), current: world.snapshot(),
                                                          available: world.records()))
        XCTAssertNil(recovery.blocker)
        XCTAssertEqual(recovery.displayNames.count, 1)
        try sut.recoverCurrentDesktop(recovery, hideAgain: true, store: store)
        XCTAssertEqual(world.writes, ["off 8"])
        XCTAssertEqual(world.mirrors, [:])
        XCTAssertTrue(try store.load().state.resolved)
    }
}
