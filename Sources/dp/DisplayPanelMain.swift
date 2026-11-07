import Foundation
import DisplayPanelCore
import Darwin

@main
struct DisplayPanelMain {
    static func main() {
        do {
            if ProcessInfo.processInfo.environment["DISPLAYPANEL_CLEANUP_ONLY"] == "1" {
                let ruleID = ProcessInfo.processInfo.environment["DISPLAYPANEL_CLEANUP_RULE_ID"]
                    .flatMap(UUID.init(uuidString:))
                let succeeded = BlackoutController.retryBrightnessCleanup(ruleID: ruleID)
                let status = BlackoutRuntimeStatus(
                    state: .stopped, blackedOutDisplayIDs: [], cleanupSucceeded: succeeded
                )
                FileHandle.standardOutput.write(try JSONEncoder().encode(status))
                FileHandle.standardOutput.write(Data([0x0A]))
                Foundation.exit(succeeded ? 0 : EXIT_FAILURE)
            }
            let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .list(let json): try DisplayInventory.printRecords(DisplayInventory.records(), json: json)
            case .probe(let json): try Probe.printReport(Probe.report(), json: json)
            case .mirror(let selector, let source, let journalPath):
                try DisplayMirroring.mirror(selector: selector, source: source, journalPath: journalPath)
            case .unmirror(let journalPath):
                try DisplayMirroring.unmirror(journalPath: journalPath)
            case .unmirrorTarget(let selector, let journalPath):
                try DisplayMirroring.unmirror(selector: selector, journalPath: journalPath)
            case .away(let selector, let source, let input, let journalPath):
                try DisplayHandoff.run(selector: selector, source: source, input: input, journalPath: journalPath)
            case .back(let selector, let input, let journalPath):
                try DisplayHandoff.run(selector: selector, source: nil, input: input, journalPath: journalPath)
            case .recovery(let action, let timeout, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.run(action: action, timeout: timeout, journalPath: journalPath, executable: executable)
            case .recoverySelected(let action, let timeout, let selector, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.run(action: action, timeout: timeout, journalPath: journalPath,
                                       displaySelector: selector, executable: executable)
            case .recoveryDisable(let selector, let timeout, let journalPath):
                guard let executable = Bundle.main.executableURL else {
                    throw RecoveryError.unsafe("cannot locate watchdog executable")
                }
                try DisplayRecovery.disable(selector: selector, timeout: timeout, journalPath: journalPath, executable: executable)
            case .recoveryHelper(let journalPath, let id):
                try DisplayRecovery.runHelper(journalPath: journalPath, id: id)
            case .blackout(let options):
                let controller = blackoutController()
                try controller.run(options: options)
            case .ddcLuminance(let selector, let setValue, let json):
                if let setValue {
                    let result = try DDCLuminance.set(selector: selector, value: setValue)
                    if json {
                        try printJSON(result)
                    } else {
                        print(Output.luminance(result, names: Output.names()))
                    }
                } else {
                    let reading = try DDCLuminance.read(selector: selector)
                    if json {
                        try printJSON(reading)
                    } else {
                        print(Output.luminance(reading, names: Output.names()))
                    }
                }
            case .ddcInput(let selector, let setValue, let json):
                if let setValue {
                    let result = try DDCInput.set(selector: selector, value: setValue)
                    if json {
                        try printJSON(result)
                    } else {
                        print(Output.input(result, names: Output.names()))
                    }
                } else {
                    let reading = try DDCInput.read(selector: selector)
                    if json {
                        try printJSON(reading)
                    } else {
                        print(Output.input(reading, names: Output.names()))
                    }
                }
            case .ddcPower(let selector, let value, let acceptedRisk, let json):
                let result = try DDCPower.run(selector: selector, value: value, acceptedRisk: acceptedRisk)
                if json {
                    try printJSON(result)
                } else {
                    print(Output.power(result, names: Output.names()))
                }
            case .sleepDisplays(let keepSystemAwake, let timeout):
                let controller = DisplaySleepController()
                try controller.start(keepSystemAwake: keepSystemAwake, timeout: timeout)
                if keepSystemAwake {
                    controller.runUntilTermination()
                    controller.stop()
                }
            case .wakeDisplays:
                try DisplaySleepController.wake()
            case .appStatusWatch:
                let client = try AppControlClient()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let code = try client.watchStatus { response in
                    var data = try encoder.encode(response)
                    data.append(0x0A)
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
                exit(code)
            case .app(let appCommand, let durationSeconds, let targetUUID, let actionID, let ruleID, let hideStyle,
                      let refreshRate, let json):
                let client = try AppControlClient()
                let response: AppControlResponse
                do {
                    response = try client.execute(
                        appCommand,
                        durationSeconds: durationSeconds,
                        targetUUID: targetUUID,
                        actionID: actionID,
                        ruleID: ruleID,
                        hideStyle: hideStyle,
                        refreshRate: refreshRate
                    )
                } catch {
                    guard appCommand.isManualDisplayCommand else { throw error }
                    // A transport failure does not prove whether the request was received.
                    response = AppControlResponse(
                        ok: false, running: true, enabled: false, state: "unknown",
                        summary: "App control result unavailable; inspect status before retrying.",
                        error: error.localizedDescription, outcome: .responseLost
                    )
                }
                if json {
                    try printJSON(response)
                } else if let steps = response.steps, !steps.isEmpty {
                    let text = Output.steps(steps, names: Output.names())
                    if response.ok {
                        print(steps.count > 1 ? text + "\n" + response.summary : text)
                    } else if steps.count > 1 {
                        print(text)
                        fputs("dp: \(response.summary)\n", stderr)
                    } else {
                        fputs("dp: \(text)\n", stderr)
                    }
                } else if appCommand == .status {
                    print(Output.status(response, names: response.displays == nil ? [:] : Output.names()))
                } else if response.ok {
                    print([response.summary, response.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                } else {
                    fputs("dp: \(response.error ?? response.summary)\n", stderr)
                }
                noteNewerApp(response.version)
                if response.exitCode != 0 {
                    Foundation.exit(response.exitCode)
                }
            case .help(let command):
                print(CLIHelp.text(for: command))
            case .version:
                print(CLIHelp.version)
            }
        } catch let error as CLIParseError {
            fputs("dp: \(error)\n", stderr)
            fputs("Try 'dp help' for usage.\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("dp: \(error)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func blackoutController() -> BlackoutController {
        let controller: BlackoutController
        if ProcessInfo.processInfo.environment["DISPLAYPANEL_EMIT_STATUS"] == "1" {
            controller = BlackoutController { status in
                guard let data = try? JSONEncoder().encode(status) else { return }
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } else {
            controller = BlackoutController()
        }
        if ProcessInfo.processInfo.environment["DISPLAYPANEL_PARENT_PIPE"] == "1" {
            monitorParentPipe(controller)
        }
        return controller
    }

    private static func monitorParentPipe(_ controller: BlackoutController) {
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    pending.append(contentsOf: buffer.prefix(count))
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        guard let value = String(data: line, encoding: .utf8) else { continue }
                        if value.hasPrefix("relocation:"),
                           let payload = Data(base64Encoded: String(value.dropFirst("relocation:".count))),
                           let control = try? JSONDecoder().decode(BlackoutRelocationControl.self, from: payload) {
                            DispatchQueue.main.async { controller.handleRelocationControl(control) }
                        } else if let command = BlackoutControlCommand(rawValue: value) {
                            DispatchQueue.main.async { controller.handleControl(command) }
                        }
                    }
                    if pending.count <= 65_536 { continue }
                }
                if count < 0, errno == EINTR { continue }
                DispatchQueue.main.async {
                    controller.stop()
                }
                return
            }
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        print()
    }

    /// An older `dp` still talks to a newer app, but may not know its newer replies.
    private static func noteNewerApp(_ appVersion: String?) {
        let cliVersion = String(CLIHelp.version.dropFirst("dp ".count))
        guard let appVersion, appVersion.compare(cliVersion, options: .numeric) == .orderedDescending else { return }
        fputs("DisplayPanel \(appVersion) is running; this dp is \(cliVersion).\n", stderr)
    }
}
