import Foundation
import XCTest

// Kept identical in DisplayPanelAppTests/TestIsolation.swift.
//
// Test state is named after the test, never a UUID or PID, so a rerun reuses the
// same plist and directory instead of adding new ones. Each helper clears its
// state on creation, which also cleans up after a crashed earlier run, and again
// in a teardown block, which still runs after an early throw.
extension XCTestCase {
    /// `<Class>.<method>`, from XCTest's `-[Class method]`.
    var testIdentifier: String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).replacingOccurrences(of: " ", with: ".")
    }

    /// An empty UserDefaults suite for this test. Pass a distinct `label` for each
    /// extra suite in one test.
    func makeTestDefaults(_ label: String = "") throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "displaypanel-test-\(testIdentifier)" + (label.isEmpty ? "" : "-\(label)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }

    /// An empty 0700 directory owned by this test and removed in teardown. Sockets,
    /// helper scripts and child-process output belong here. The name is a hash of
    /// the test so socket paths stay under the 104-byte `sun_path` limit.
    func makeTestDirectory(_ label: String = "") throws -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in testIdentifier.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("displaypanel-test-\(String(hash, radix: 16))", isDirectory: true)
        let directory = label.isEmpty ? root : root.appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return directory
    }
}
