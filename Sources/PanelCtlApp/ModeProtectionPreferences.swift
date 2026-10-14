import Foundation
import PanelCtlCore

struct ProtectedDisplayMode: Codable, Equatable, Identifiable {
    var saved: SavedDisplayMode
    var enabled = false
    var id: String { saved.uuid.lowercased() }
}

struct ModeProtectionPreferences: Codable, Equatable {
    var displays: [ProtectedDisplayMode] = []

    func validate() throws {
        guard Set(displays.map(\.id)).count == displays.count else {
            throw ArrangementProtectionError("Duplicate protected display identities.")
        }
        for display in displays { try display.saved.validate() }
    }
}
