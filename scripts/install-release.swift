#!/usr/bin/env swift

import AppKit
import Foundation

enum InstallError: LocalizedError {
    case usage
    case invalidSource(String)
    case invalidDestination(String)
    case destinationRunning(String)
    case gatekeeperRejected(String)
    case quarantineNotCleared(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: install-release.swift SOURCE_APP DESTINATION_APP"
        case .invalidSource(let path):
            return "source app bundle not found: \(path)"
        case .invalidDestination(let path):
            return "destination must be an absolute .app path: \(path)"
        case .destinationRunning(let path):
            return "app is still running after being asked to quit: \(path)"
        case .gatekeeperRejected(let path):
            return "Gatekeeper rejected the downloaded app: \(path)"
        case .quarantineNotCleared(let path):
            return "could not clear quarantine: \(path)"
        }
    }
}

func terminateRunningApp(at destination: URL) throws {
    guard let bundleIdentifier = Bundle(url: destination)?.bundleIdentifier else { return }
    let runningApps = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).filter { app in
        app.bundleURL?.standardizedFileURL == destination
    }
    guard !runningApps.isEmpty else { return }

    runningApps.forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while runningApps.contains(where: { !$0.isTerminated }), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard runningApps.allSatisfy(\.isTerminated) else {
        throw InstallError.destinationRunning(destination.path)
    }
}

func run(_ tool: String, _ arguments: [String]) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// A copied download keeps its quarantine, so macOS would run it translocated
/// and refuse Launch at Login. Accept it as Finder's move would, but only after
/// Gatekeeper accepts it.
func clearQuarantine(of app: URL) throws {
    guard getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return }
    guard try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) else {
        throw InstallError.gatekeeperRejected(app.path)
    }
    guard try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path]) else {
        throw InstallError.quarantineNotCleared(app.path)
    }
}

func install(sourcePath: String, destinationPath: String) throws {
    let fileManager = FileManager.default
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          source.pathExtension == "app" else {
        throw InstallError.invalidSource(source.path)
    }
    guard destinationPath.hasPrefix("/"), destination.pathExtension == "app" else {
        throw InstallError.invalidDestination(destination.path)
    }

    if fileManager.fileExists(atPath: destination.path) {
        try terminateRunningApp(at: destination)
    }

    let staging = destination
        .deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).installing-\(UUID().uuidString)")
    var trashedDestination: NSURL?

    defer {
        if fileManager.fileExists(atPath: staging.path) {
            try? fileManager.removeItem(at: staging)
        }
    }

    try fileManager.copyItem(at: source, to: staging)
    try clearQuarantine(of: staging)

    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.trashItem(at: destination, resultingItemURL: &trashedDestination)
    }

    do {
        try fileManager.moveItem(at: staging, to: destination)
    } catch {
        if let trashedDestination = trashedDestination as URL?,
           !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: trashedDestination, to: destination)
        }
        throw error
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw InstallError.usage
    }
    try install(sourcePath: CommandLine.arguments[1], destinationPath: CommandLine.arguments[2])
} catch {
    FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
