import Foundation
import CoreGraphics

/// Durable identity follows saved-display settings: UUID + vendor/model/serial,
/// never a persisted numeric display address.
public struct SavedDisplayMode: Codable, Equatable {
    public let uuid: String
    public let name: String?
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let mode: RecoveryMode

    public init(display: DisplayRecord, mode: RecoveryMode) {
        uuid = display.uuid?.lowercased() ?? ""
        name = display.name
        vendor = display.vendor
        model = display.model
        serial = display.serial
        self.mode = mode
    }

    public func validate() throws {
        guard UUID(uuidString: uuid) != nil, mode.width > 0, mode.height > 0,
              mode.pixelWidth > 0, mode.pixelHeight > 0,
              mode.refreshRate.isFinite, mode.refreshRate >= 0 else {
            throw RecoveryError.unsafe("invalid saved display mode")
        }
    }

    private func resolve(in inventory: [DisplayRecord]) throws -> DisplayRecord {
        try validate()
        let matches = inventory.filter { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        guard matches.count == 1, let display = matches.first,
              display.vendor == vendor, display.model == model, display.serial == serial else {
            throw RecoveryError.unsafe("saved display identity is missing, ambiguous or changed for \(uuid)")
        }
        return display
    }

    fileprivate func visibleDisplay(in inventory: [DisplayRecord]) throws -> DisplayRecord {
        let display = try resolve(in: inventory)
        guard display.id != 0, display.active, display.online, !display.asleep else {
            throw RecoveryError.unsafe("protected display is not visible and awake")
        }
        return display
    }
}

public struct DisplayModeProtectionController {
    var recoveryStore = RecoveryStore()
    var operationLock: () -> RecoveryStore = { RecoveryStore.operationLock() }
    var records: () -> [DisplayRecord] = { DisplayInventory.records() }
    var mirrored: (UInt32) -> Bool = { CGDisplayIsInMirrorSet($0) != 0 }
    var rotation: (UInt32) -> Double = { CGDisplayRotation($0) }
    var currentMode: (UInt32) throws -> RecoveryMode = {
        guard let mode = CGDisplayCopyDisplayMode($0) else {
            throw RecoveryError.unsafe("cannot read current display mode")
        }
        return RecoveryMode(mode)
    }
    var availableModes: (UInt32) -> [RecoveryMode] = { id in
        modes(id).map(RecoveryMode.init)
    }
    var transaction = DisplayModeTransaction()
    var convergencePause: () -> Void = { Thread.sleep(forTimeInterval: 0.2) }

    public init() {}

    public func capture(uuid: String) throws -> SavedDisplayMode {
        let inventory = records()
        let matches = inventory.filter { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        guard matches.count == 1, let display = matches.first else {
            throw RecoveryError.unsafe("display identity is missing or ambiguous")
        }
        let saved = SavedDisplayMode(display: display, mode: try currentMode(display.id))
        _ = try eligible(saved, inventory: inventory)
        return saved
    }

    public func isAvailable(_ saved: SavedDisplayMode) throws -> Bool {
        let display = try eligible(saved, inventory: records())
        return availableModes(display.id).contains(saved.mode)
    }

    /// One session-only commit. Both locks and fresh topology/identity checks
    /// surround staging and commit; verification never retries a write.
    @discardableResult
    public func restore(_ saved: SavedDisplayMode, revalidate: () throws -> Void = {}) throws -> Bool {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try recoveryStore.lock()
        defer { recoveryStore.unlock() }
        try requireClearJournal()
        try revalidate()
        let before = records()
        let display = try eligible(saved, inventory: before)
        let mirrorStates = before.map { mirrored($0.id) }
        let rotations = before.map { rotation($0.id) }
        let originalMode = try currentMode(display.id)
        guard originalMode != saved.mode else { return false }
        guard availableModes(display.id).contains(saved.mode) else {
            throw RecoveryError.unsafe("saved mode unavailable for \(saved.uuid): \(saved.mode.description)")
        }
        func boundary() throws {
            try revalidate()
            try requireClearJournal()
            let fresh = records()
            guard fresh == before, fresh.map({ mirrored($0.id) }) == mirrorStates,
                  fresh.map({ rotation($0.id) }) == rotations,
                  try eligible(saved, inventory: fresh).id == display.id,
                  try currentMode(display.id) == originalMode,
                  availableModes(display.id).contains(saved.mode) else {
                throw RecoveryError.unsafe("display topology, identity or mode changed at the write boundary")
            }
        }
        try transaction.apply(display.id, saved.mode, boundary)
        for attempt in 0..<6 {
            try revalidate()
            let observed = try eligible(saved, inventory: records())
            guard observed.id == display.id else {
                throw RecoveryError.unsafe("display identity changed during mode verification")
            }
            if try currentMode(display.id) == saved.mode { return true }
            if attempt < 5 { convergencePause() }
        }
        throw RecoveryError.unsafe("saved display mode did not verify")
    }

    private func eligible(_ saved: SavedDisplayMode, inventory: [DisplayRecord]) throws -> DisplayRecord {
        guard Set(inventory.map(\.id)).count == inventory.count else {
            throw RecoveryError.unsafe("duplicate display addresses")
        }
        let display = try saved.visibleDisplay(in: inventory)
        guard !mirrored(display.id) else { throw RecoveryError.unsafe("mirrored displays are owned by recovery") }
        return display
    }

    private func requireClearJournal() throws {
        if try recoveryStore.exists(), try !recoveryStore.load().state.resolved {
            throw RecoveryError.unsafe("unresolved journal; recovery owns display modes")
        }
    }

    fileprivate static func modes(_ id: UInt32) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }
}

/// Same closure-injected CG transaction seam as arrangement and recovery.
struct DisplayModeTransaction {
    var begin: () throws -> CGDisplayConfigRef = {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config))
        guard let config else { throw RecoveryError.unsafe("missing mode configuration transaction") }
        return config
    }
    var prepare: (UInt32, RecoveryMode) throws -> (CGDisplayConfigRef) throws -> Void = { id, saved in
        guard let mode = DisplayModeProtectionController.modes(id).first(where: { RecoveryMode($0) == saved }) else {
            throw RecoveryError.unsafe("saved mode unavailable at the write boundary")
        }
        return { try check(CGConfigureDisplayWithDisplayMode($0, id, mode, nil)) }
    }
    var complete: (CGDisplayConfigRef, CGConfigureOption) throws -> Void = {
        try check(CGCompleteDisplayConfiguration($0, $1))
    }
    var cancel: (CGDisplayConfigRef) -> Void = { _ = CGCancelDisplayConfiguration($0) }

    func apply(_ id: UInt32, _ mode: RecoveryMode, _ boundary: () throws -> Void) throws {
        let stage = try prepare(id, mode)
        try boundary()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        try stage(config)
        try boundary()
        consumed = true
        try complete(config, .forSession)
    }

    private static func check(_ result: CGError) throws {
        guard result == .success else { throw RecoveryError.unsafe("mode configuration failed (CGError \(result.rawValue))") }
    }
}
