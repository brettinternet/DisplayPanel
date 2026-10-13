import Foundation
import PanelCtlCore

struct ArrangementPreferences: Codable, Equatable {
    var enabled = false
    var applyOnLaunch = false
    var remembered: [PanelCtlCore.DisplayArrangement] = []
    var preferredMain: DisplayArrangementMember?

    func validate() throws {
        guard Set(remembered.map(\.setKey)).count == remembered.count else {
            throw ArrangementProtectionError("Duplicate remembered display sets.")
        }
        for arrangement in remembered {
            try arrangement.validate()
            guard arrangement.members.count >= 2 else {
                throw ArrangementProtectionError("A remembered arrangement needs at least two displays.")
            }
        }
        if let preferredMain, UUID(uuidString: preferredMain.uuid) == nil {
            throw ArrangementProtectionError("Invalid preferred main display identity.")
        }
    }
}

struct ArrangementProtectionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ArrangementRestorePlan {
    let current: PanelCtlCore.DisplayArrangement
    let desired: PanelCtlCore.DisplayArrangement
    let excluded: Set<String>
    let preferences: ArrangementPreferences
}
