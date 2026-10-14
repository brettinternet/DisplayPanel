import Foundation
import CoreGraphics

public struct DisplayArrangementMember: Codable, Equatable {
    public var uuid: String
    public var id: UInt32
    public var name: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var x: Int32
    public var y: Int32
    public var width: Double
    public var height: Double
    public var rotation: Double
    public var main: Bool

    public init(uuid: String, id: UInt32, name: String?, vendor: UInt32, model: UInt32,
                serial: UInt32, x: Int32, y: Int32, width: Double, height: Double,
                rotation: Double, main: Bool) {
        self.uuid = uuid
        self.id = id
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.main = main
    }
}

public struct DisplayArrangement: Codable, Equatable {
    public var members: [DisplayArrangementMember]
    public var relationships: [DisplayArrangementRelationship]?

    public init(members: [DisplayArrangementMember]) {
        self.members = members
    }

    /// A stable key for the exact UUID set, independent of member order or case.
    public var setKey: String {
        Set(members.map { Self.identityKey($0.uuid) }).sorted().joined(separator: ",")
    }

    public func validate() throws {
        guard !members.isEmpty, members.count <= 128,
              members.allSatisfy({ UUID(uuidString: $0.uuid) != nil && $0.id != 0 }),
              Set(members.map { Self.identityKey($0.uuid) }).count == members.count,
              Set(members.map(\.id)).count == members.count else {
            throw RecoveryError.unsafe("invalid or duplicate display arrangement identities")
        }
        guard members.allSatisfy({ $0.width.isFinite && $0.width > 0 && $0.height.isFinite && $0.height > 0 && $0.rotation.isFinite }) else {
            throw RecoveryError.unsafe("invalid display arrangement dimensions or rotation")
        }
        guard members.filter(\.main).count == 1,
              let main = members.first(where: \.main), main.x == 0, main.y == 0 else {
            throw RecoveryError.unsafe("display arrangement must have one main display at origin 0,0")
        }
    }

    /// Binds saved stable identities to the current display IDs. Numeric IDs and
    /// names may change; physical identity and geometry may not.
    public func restoring(_ saved: Self) throws -> Self {
        try validate()
        try saved.validate()
        guard members.count == saved.members.count,
              Set(members.map { Self.identityKey($0.uuid) }) == Set(saved.members.map { Self.identityKey($0.uuid) }) else {
            throw RecoveryError.unsafe("display arrangement set changed")
        }

        let savedByUUID = Dictionary(uniqueKeysWithValues: saved.members.map { (Self.identityKey($0.uuid), $0) })
        let restored = try members.map { current -> DisplayArrangementMember in
            guard let previous = savedByUUID[Self.identityKey(current.uuid)],
                  Self.sameHardwareIdentity(current, previous) else {
                throw RecoveryError.unsafe("display identity changed for \(current.uuid)")
            }
            guard current.width == previous.width, current.height == previous.height,
                  current.rotation == previous.rotation else {
                throw RecoveryError.unsafe("display dimensions or rotation changed for \(current.uuid)")
            }
            var result = current
            result.x = previous.x
            result.y = previous.y
            result.main = previous.main
            return result
        }
        let arrangement = Self(members: restored)
        try arrangement.validate()
        return arrangement
    }

    /// Selects an existing member as main while preserving all relative origins.
    public func preferringMain(_ preferred: DisplayArrangementMember) throws -> Self? {
        try validate()
        guard UUID(uuidString: preferred.uuid) != nil else {
            throw RecoveryError.unsafe("invalid preferred display identity")
        }
        guard let selected = members.first(where: { Self.identityKey($0.uuid) == Self.identityKey(preferred.uuid) }) else {
            return nil
        }
        guard Self.sameHardwareIdentity(selected, preferred) else {
            throw RecoveryError.unsafe("preferred display identity changed for \(selected.uuid)")
        }

        let shifted = try members.map { member -> DisplayArrangementMember in
            let x = Int64(member.x) - Int64(selected.x)
            let y = Int64(member.y) - Int64(selected.y)
            guard let translatedX = Int32(exactly: x), let translatedY = Int32(exactly: y) else {
                throw RecoveryError.unsafe("preferred main translation exceeds display origin range")
            }
            var result = member
            result.x = translatedX
            result.y = translatedY
            result.main = Self.identityKey(member.uuid) == Self.identityKey(selected.uuid)
            return result
        }
        let arrangement = Self(members: shifted)
        try arrangement.validate()
        return arrangement
    }

    /// Compares stable identity and placement, ignoring display names and IDs.
    public func samePlacement(as other: Self) -> Bool {
        guard members.count == other.members.count else { return false }
        let left = Dictionary(grouping: members, by: { Self.identityKey($0.uuid) })
        let right = Dictionary(grouping: other.members, by: { Self.identityKey($0.uuid) })
        guard left.count == members.count, right.count == other.members.count,
              Set(left.keys) == Set(right.keys) else { return false }
        for (uuid, leftMembers) in left {
            guard leftMembers.count == 1, let lhs = leftMembers.first,
                  let rightMembers = right[uuid], rightMembers.count == 1, let rhs = rightMembers.first,
                  Self.sameHardwareIdentity(lhs, rhs), lhs.x == rhs.x, lhs.y == rhs.y,
                  lhs.width == rhs.width, lhs.height == rhs.height,
                  lhs.rotation == rhs.rotation, lhs.main == rhs.main else { return false }
        }
        return true
    }

    static func identityKey(_ uuid: String) -> String {
        UUID(uuidString: uuid)?.uuidString.lowercased() ?? uuid.lowercased()
    }

    private static func sameHardwareIdentity(_ lhs: DisplayArrangementMember,
                                             _ rhs: DisplayArrangementMember) -> Bool {
        identityKey(lhs.uuid) == identityKey(rhs.uuid) && lhs.vendor == rhs.vendor &&
            lhs.model == rhs.model && lhs.serial == rhs.serial
    }
}

/// Public CoreGraphics origin-only arrangement controller. It never writes
/// modes, mirrors, color state, permanent preferences, or hardware controls.
public struct DisplayArrangementController {
    var recoveryStore: RecoveryStore
    var operationLock: () -> RecoveryStore
    var records: () -> [DisplayRecord]
    var mirrorOf: (UInt32) -> UInt32
    var rotation: (UInt32) -> Double
    var transaction: DisplayArrangementTransaction
    var convergencePause: () -> Void

    public init() {
        self.init(recoveryStore: RecoveryStore(), operationLock: { RecoveryStore.operationLock() })
    }

    init(recoveryStore: RecoveryStore = RecoveryStore(),
         operationLock: @escaping () -> RecoveryStore = { RecoveryStore.operationLock() },
         records: @escaping () -> [DisplayRecord] = { DisplayInventory.records() },
         mirrorOf: @escaping (UInt32) -> UInt32 = { CGDisplayMirrorsDisplay($0) },
         rotation: @escaping (UInt32) -> Double = { CGDisplayRotation($0) },
         transaction: DisplayArrangementTransaction = DisplayArrangementTransaction(),
         convergencePause: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.2) }) {
        self.recoveryStore = recoveryStore
        self.operationLock = operationLock
        self.records = records
        self.mirrorOf = mirrorOf
        self.rotation = rotation
        self.transaction = transaction
        self.convergencePause = convergencePause
    }

    public func capture(excluding: Set<String> = []) throws -> DisplayArrangement {
        let inventory = records()
        guard !inventory.isEmpty, inventory.count <= 128,
              inventory.allSatisfy({ $0.uuid.map { UUID(uuidString: $0) != nil } == true && $0.id != 0 }),
              Set(inventory.compactMap { $0.uuid.map(DisplayArrangement.identityKey) }).count == inventory.count,
              Set(inventory.map(\.id)).count == inventory.count else {
            throw RecoveryError.unsafe("display inventory has missing, invalid, or duplicate identities")
        }

        for display in inventory {
            guard display.online, display.active else {
                throw RecoveryError.unsafe("display inventory contains an offline or inactive display")
            }
            guard !display.asleep else {
                throw RecoveryError.unsafe("display inventory contains an asleep display")
            }
            guard mirrorOf(display.id) == kCGNullDirectDisplay else {
                throw RecoveryError.unsafe("mirrored displays cannot be arranged")
            }
        }

        let excluded = Set(excluding.map(DisplayArrangement.identityKey))
        if inventory.contains(where: { $0.main && excluded.contains(DisplayArrangement.identityKey($0.uuid!)) }) {
            throw RecoveryError.unsafe("cannot exclude the main display from an arrangement")
        }
        let included = inventory.filter { !excluded.contains(DisplayArrangement.identityKey($0.uuid!)) }
        let members = try included.map { display -> DisplayArrangementMember in
            guard let x = Int32(exactly: display.bounds.x), let y = Int32(exactly: display.bounds.y) else {
                throw RecoveryError.unsafe("display \(display.id) has an unrepresentable origin")
            }
            return DisplayArrangementMember(
                uuid: DisplayArrangement.identityKey(display.uuid!), id: display.id, name: display.name,
                vendor: display.vendor, model: display.model, serial: display.serial,
                x: x, y: y, width: display.bounds.width, height: display.bounds.height,
                rotation: rotation(display.id), main: display.main
            )
        }
        let arrangement = DisplayArrangement(members: members)
        try arrangement.validate()
        return arrangement
    }

    /// Restores origins only. Identity and topology are checked while holding
    /// the same operation and default-journal locks used by recovery writers.
    @discardableResult
    public func restore(_ desired: DisplayArrangement, expected: DisplayArrangement,
                        excluding: Set<String> = [], revalidate: () throws -> Void = {}) throws -> Bool {
        let operation = operationLock()
        try operation.lock()
        defer { operation.unlock() }
        try recoveryStore.lock()
        defer { recoveryStore.unlock() }
        try requireClearJournal()
        try desired.validate()
        try expected.validate()
        try revalidate()

        let excluded = Set(excluding.map(DisplayArrangement.identityKey))
        let fullCurrent = try capture()
        guard let oldMain = fullCurrent.members.first(where: \.main),
              !excluded.contains(DisplayArrangement.identityKey(oldMain.uuid)) else {
            throw RecoveryError.unsafe("cannot exclude the main display from an arrangement")
        }
        let visibleCurrent = Self.project(fullCurrent, excluding: excluded)
        try Self.requireExpected(expected, visibleCurrent)
        let visibleDesired = Self.project(desired, excluding: excluded)
        let visibleTarget = try visibleCurrent.restoring(visibleDesired)
        guard let desiredOldMain = visibleTarget.members.first(where: {
            DisplayArrangement.identityKey($0.uuid) == DisplayArrangement.identityKey(oldMain.uuid)
        }) else {
            throw RecoveryError.unsafe("the current main display is missing from the desired arrangement")
        }
        let deltaX = Int64(desiredOldMain.x) - Int64(oldMain.x)
        let deltaY = Int64(desiredOldMain.y) - Int64(oldMain.y)
        let translatedExcluded = try fullCurrent.members.filter {
            excluded.contains(DisplayArrangement.identityKey($0.uuid))
        }.map { member -> DisplayArrangementMember in
            guard let x = Int32(exactly: Int64(member.x) + deltaX),
                  let y = Int32(exactly: Int64(member.y) + deltaY) else {
                throw RecoveryError.unsafe("excluded display translation exceeds origin range")
            }
            var translated = member
            translated.x = x
            translated.y = y
            return translated
        }
        let target = DisplayArrangement(members: visibleTarget.members + translatedExcluded)
        try target.validate()
        guard !fullCurrent.samePlacement(as: target) else { return false }

        let validateBoundary = {
            try revalidate()
            let fresh = try self.capture()
            try Self.requireExpected(expected, Self.project(fresh, excluding: excluded))
            try Self.requireExpected(fullCurrent, fresh)
        }
        try transaction.apply(target, current: fullCurrent, validateBoundary: validateBoundary)
        try converge(target, revalidate: revalidate)
        return true
    }

    private func requireClearJournal() throws {
        guard try recoveryStore.exists() else { return }
        let journal = try recoveryStore.load()
        guard journal.state.resolved else {
            throw RecoveryError.unsafe("unresolved journal; inspect status and recover before arranging displays")
        }
    }

    private func converge(_ target: DisplayArrangement, revalidate: () throws -> Void) throws {
        var lastError: Error?
        for attempt in 0..<6 {
            do {
                try revalidate()
                let observed = try capture()
                guard target.samePlacement(as: observed), Self.sameIDs(target, observed) else {
                    throw RecoveryError.unsafe("display arrangement did not verify")
                }
                return
            } catch {
                lastError = error
                if attempt < 5 { convergencePause() }
            }
        }
        throw lastError ?? RecoveryError.unsafe("display arrangement did not verify")
    }

    private static func project(_ arrangement: DisplayArrangement,
                                excluding: Set<String>) -> DisplayArrangement {
        DisplayArrangement(members: arrangement.members.filter {
            !excluding.contains(DisplayArrangement.identityKey($0.uuid))
        })
    }

    private static func requireExpected(_ expected: DisplayArrangement,
                                        _ current: DisplayArrangement) throws {
        guard expected.samePlacement(as: current), sameIDs(expected, current) else {
            throw RecoveryError.unsafe("display topology or IDs changed; arrangement cancelled")
        }
    }

    private static func sameIDs(_ lhs: DisplayArrangement, _ rhs: DisplayArrangement) -> Bool {
        guard lhs.members.count == rhs.members.count else { return false }
        let ids = Dictionary(uniqueKeysWithValues: lhs.members.map { (DisplayArrangement.identityKey($0.uuid), $0.id) })
        return rhs.members.allSatisfy { ids[DisplayArrangement.identityKey($0.uuid)] == $0.id }
    }
}

struct DisplayArrangementTransaction {
    var begin: () throws -> CGDisplayConfigRef = {
        var config: CGDisplayConfigRef?
        let result = CGBeginDisplayConfiguration(&config)
        guard result == .success, let config else {
            throw RecoveryError.unsafe("begin display arrangement failed (CGError \(result.rawValue))")
        }
        return config
    }
    var origin: (CGDisplayConfigRef, UInt32, Int32, Int32) throws -> Void = { config, id, x, y in
        let result = CGConfigureDisplayOrigin(config, id, x, y)
        guard result == .success else {
            throw RecoveryError.unsafe("stage display origin failed (CGError \(result.rawValue))")
        }
    }
    var complete: (CGDisplayConfigRef, CGConfigureOption) throws -> Void = { config, scope in
        let result = CGCompleteDisplayConfiguration(config, scope)
        guard result == .success else {
            throw RecoveryError.unsafe("complete display arrangement failed (CGError \(result.rawValue))")
        }
    }
    var cancel: (CGDisplayConfigRef) -> Void = { _ = CGCancelDisplayConfiguration($0) }

    func apply(_ desired: DisplayArrangement, current: DisplayArrangement,
               validateBoundary: () throws -> Void) throws {
        try validateBoundary()
        let config = try begin()
        var consumed = false
        defer { if !consumed { cancel(config) } }
        let currentByUUID = Dictionary(uniqueKeysWithValues: current.members.map {
            (DisplayArrangement.identityKey($0.uuid), $0)
        })
        let changedMembers = try desired.members.map { member -> (DisplayArrangementMember, DisplayArrangementMember) in
            guard let previous = currentByUUID[DisplayArrangement.identityKey(member.uuid)] else {
                throw RecoveryError.unsafe("display disappeared while arranging")
            }
            return (member, previous)
        }
        let hasChanges = changedMembers.contains { member, previous in
            member.x != previous.x || member.y != previous.y || member.main != previous.main
        }
        guard hasChanges else { return }
        for (member, previous) in changedMembers where !member.main {
            if member.x != previous.x || member.y != previous.y || member.main != previous.main {
                try origin(config, member.id, member.x, member.y)
            }
        }
        if let main = changedMembers.first(where: { $0.0.main })?.0 {
            try origin(config, main.id, main.x, main.y)
        } else {
            throw RecoveryError.unsafe("display arrangement has no main member")
        }
        try validateBoundary()
        consumed = true
        try complete(config, .forSession)
    }
}
