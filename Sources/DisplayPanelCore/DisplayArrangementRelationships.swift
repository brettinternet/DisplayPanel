import Foundation

public struct DisplayArrangementRelationship: Codable, Equatable {
    public enum Side: String, Codable { case left, right, above, below }
    public enum Alignment: String, Codable { case start, end, offset }

    public var referenceUUID: String
    public var memberUUID: String
    public var side: Side
    public var alignment: Alignment
    public var offset: Double
}

extension DisplayArrangement {
    /// Keep exact geometry even when it cannot be represented by neighbor rules.
    /// Older saves omit relationships; they infer the same rules when needed.
    public func rememberingRelationships() throws -> Self {
        try validate()
        var saved = self
        saved.relationships = try? inferredRelationships()
        return saved
    }

    /// Adapt remembered layouts only. The transaction controller still requires
    /// exact dimensions/rotation, including at both write boundaries.
    public func restoringRemembered(_ saved: Self) throws -> Self {
        try validate()
        try saved.validate()
        let currentByUUID = Dictionary(uniqueKeysWithValues: members.map { (Self.identityKey($0.uuid), $0) })
        var matched = saved
        var geometryChanged = false
        for index in matched.members.indices {
            guard let current = currentByUUID[Self.identityKey(matched.members[index].uuid)] else {
                throw RecoveryError.unsafe("display arrangement set changed")
            }
            let previous = matched.members[index]
            geometryChanged = geometryChanged || current.width != previous.width ||
                current.height != previous.height || current.rotation != previous.rotation
            matched.members[index].width = current.width
            matched.members[index].height = current.height
            matched.members[index].rotation = current.rotation
        }
        // Reuse strict identity binding and preserve current numeric IDs/metadata.
        var target = try restoring(matched)
        guard geometryChanged else { return target }

        let inferred = try saved.inferredRelationships()
        if let stored = saved.relationships, stored != inferred {
            throw RecoveryError.unsafe("remembered display relationships do not match saved geometry")
        }
        let rules = saved.relationships ?? inferred
        let indices = Dictionary(uniqueKeysWithValues: target.members.indices.map {
            (Self.identityKey(target.members[$0].uuid), $0)
        })
        for rule in rules {
            guard let referenceIndex = indices[rule.referenceUUID], let memberIndex = indices[rule.memberUUID] else {
                throw RecoveryError.unsafe("remembered display relationship has an unknown identity")
            }
            let reference = target.members[referenceIndex]
            var member = target.members[memberIndex]
            let horizontal = rule.side == .left || rule.side == .right
            let referenceStart = Double(horizontal ? reference.y : reference.x)
            let referenceLength = horizontal ? reference.height : reference.width
            let memberLength = horizontal ? member.height : member.width
            let aligned: Double
            switch rule.alignment {
            case .start: aligned = referenceStart
            case .end: aligned = referenceStart + referenceLength - memberLength
            case .offset: aligned = referenceStart + rule.offset
            }
            let x: Double, y: Double
            switch rule.side {
            case .left: x = Double(reference.x) - member.width; y = aligned
            case .right: x = Double(reference.x) + reference.width; y = aligned
            case .above: x = aligned; y = Double(reference.y) - member.height
            case .below: x = aligned; y = Double(reference.y) + reference.height
            }
            guard let originX = Int32(exactly: x), let originY = Int32(exactly: y) else {
                throw RecoveryError.unsafe("resized display arrangement has an unrepresentable origin")
            }
            member.x = originX
            member.y = originY
            guard Self.neighborSide(member, reference: reference) == rule.side else {
                throw RecoveryError.unsafe("resized display arrangement loses a remembered shared edge")
            }
            target.members[memberIndex] = member
        }
        try target.validate()
        // Also rejects overlap between displays on different branches and loss
        // of edge contact after a saved offset no longer fits the new size.
        _ = try target.inferredRelationships()
        return target
    }

    /// A deterministic breadth-first neighbor tree rooted at the saved main.
    /// Top/left alignment wins ties (equal sizes); otherwise retain bottom/right
    /// alignment or an absolute top/left offset in logical points.
    private func inferredRelationships() throws -> [DisplayArrangementRelationship] {
        try validate()
        let ordered = members.sorted { Self.identityKey($0.uuid) < Self.identityKey($1.uuid) }
        for (index, lhs) in ordered.enumerated() {
            for rhs in ordered.dropFirst(index + 1) {
                if max(Double(lhs.x), Double(rhs.x)) < min(Double(lhs.x) + lhs.width, Double(rhs.x) + rhs.width),
                   max(Double(lhs.y), Double(rhs.y)) < min(Double(lhs.y) + lhs.height, Double(rhs.y) + rhs.height) {
                    throw RecoveryError.unsafe("display arrangement relationships would overlap displays")
                }
            }
        }
        var queue = [members.first(where: \.main)!]
        var visited = Set(queue.map { Self.identityKey($0.uuid) })
        var rules: [DisplayArrangementRelationship] = []
        var index = 0
        while index < queue.count {
            let reference = queue[index]
            index += 1
            for member in ordered where !visited.contains(Self.identityKey(member.uuid)) {
                guard let side = Self.neighborSide(member, reference: reference) else { continue }
                let horizontal = side == .left || side == .right
                let start = Double(horizontal ? member.y : member.x)
                let referenceStart = Double(horizontal ? reference.y : reference.x)
                let length = horizontal ? member.height : member.width
                let referenceLength = horizontal ? reference.height : reference.width
                let alignment: DisplayArrangementRelationship.Alignment = start == referenceStart ? .start :
                    (start + length == referenceStart + referenceLength ? .end : .offset)
                rules.append(DisplayArrangementRelationship(referenceUUID: Self.identityKey(reference.uuid),
                    memberUUID: Self.identityKey(member.uuid), side: side, alignment: alignment,
                    offset: alignment == .offset ? start - referenceStart : 0))
                visited.insert(Self.identityKey(member.uuid))
                queue.append(member)
            }
        }
        guard visited.count == members.count else {
            throw RecoveryError.unsafe("display arrangement relationships are not contiguous (shared edges required)")
        }
        return rules
    }

    private static func neighborSide(_ member: DisplayArrangementMember,
                                     reference: DisplayArrangementMember) -> DisplayArrangementRelationship.Side? {
        let x = Double(member.x), y = Double(member.y)
        let rx = Double(reference.x), ry = Double(reference.y)
        if max(y, ry) < min(y + member.height, ry + reference.height) {
            if x == rx + reference.width { return .right }
            if x + member.width == rx { return .left }
        }
        if max(x, rx) < min(x + member.width, rx + reference.width) {
            if y == ry + reference.height { return .below }
            if y + member.height == ry { return .above }
        }
        return nil
    }
}
