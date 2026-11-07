import Foundation
import DisplayPanelCore

/// Human text for `dp` results; `--json` prints the same values for scripts.
enum Output {
    /// Local display names by uppercased UUID; the app protocol carries only UUIDs.
    static func names() -> [String: String] {
        Dictionary(DisplayInventory.records().compactMap { record in
            record.uuid.map { ($0.uppercased(), record.name ?? "Display \(record.id)") }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func name(_ uuid: String, _ names: [String: String]) -> String {
        names[uuid.uppercased()] ?? uuid
    }

    // MARK: App

    static func status(_ response: AppControlResponse, names: [String: String]) -> String {
        var lines = [response.summary]
        if let detail = response.detail, !detail.isEmpty { lines.append(detail) }
        if let action = response.runningAction {
            lines.append("Running \(action.name) · step \(action.currentStep) of \(action.totalSteps)")
        }
        if let rule = response.runningRule { lines.append("Running \(rule.name) once") }
        if let displays = response.displays, !displays.isEmpty {
            lines += ["", "Displays", CLIText.table(displays.map { [name($0.targetUUID, names), display($0)] }, indent: "  ")]
        }
        if let rules = response.rules, !rules.isEmpty {
            var rows: [[String]] = []
            for rule in rules {
                guard rule.enabled else { rows.append([rule.name, "Off"]); continue }
                var text = rule.summary
                if let seconds = rule.secondsRemaining, let action = rule.nextAction {
                    text += " · \(CLIText.countdown(seconds)) to \(action)"
                }
                rows.append([rule.name, text])
                if let detail = rule.detail, !detail.isEmpty { rows.append(["", detail]) }
            }
            lines += ["", "Rules", CLIText.table(rows, indent: "  ")]
        }
        if let arrangement = response.arrangement {
            lines += ["", "Arrangement", "  " + arrangement.reason + (arrangement.differs ? " Current positions differ." : "")]
        }
        return lines.joined(separator: "\n")
    }

    static func display(_ status: AppControlDisplayStatus) -> String {
        let state: String
        switch (status.operation, status.observedState) {
        case ("hiding", _): state = "Hiding…"
        case ("showing", _): state = "Showing…"
        case (_, "separate"): state = "On desktop"
        case (_, "hidden-by-displaypanel"): state = "Hidden"
        case (_, "recovery-needed"), (_, "unsupported-recovery"): state = "Needs recovery"
        case (_, "mirrored-externally"): state = "Mirrored by macOS"
        case (_, "unavailable"): state = "Unavailable"
        default: state = "Unknown"
        }
        var parts = [state]
        if status.recoveryNeeded, state != "Needs recovery", state != "Unknown" { parts.append("needs recovery") }
        if let input = status.lastInputOutcome,
           let text = inputText(input.state, input.observedInput ?? input.requestedInput) {
            parts.append(text)
        }
        switch status.windowEnforcement?.state {
        case .armed?, .enforcing?: parts.append("keeping windows off")
        case .paused?: parts.append("keep windows off paused")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private static func inputText(_ state: DisplayInputOutcome.State, _ input: UInt8?) -> String? {
        let name = input.map(MonitorInput.name)
        switch state {
        case .verified: return name.map { "switched to \($0)" } ?? "input switched"
        case .alreadySelected: return name.map { "already on \($0)" }
        case .unverified: return "input switch unverified"
        case .failed: return "input switch failed"
        case .notRequested, .notAttempted, .skipped: return nil
        }
    }

    /// One line per step; a single-step result drops the number.
    static func steps(_ steps: [AppControlActionStepResult], names: [String: String]) -> String {
        steps.map { step in
            let target = step.targetUUID.isEmpty ? "Arrangement" : name(step.targetUUID, names)
            var line = "\(target): \(step.desktopSummary)"
            if let detail = step.inputDetail {
                line += " \(detail)"
            } else if step.inputOutcome == .unverified || step.inputOutcome == .failed {
                line += " Input switch \(step.inputOutcome == .failed ? "failed" : "unverified")."
            }
            return steps.count == 1 ? line : "\(step.index). \(line)"
        }.joined(separator: "\n")
    }

    // MARK: DDC

    static func luminance(_ reading: DDCLuminanceReading, names: [String: String]) -> String {
        "\(name(reading.uuid, names)) brightness: \(reading.current) of \(reading.maximum)"
    }

    static func luminance(_ result: DDCLuminanceWriteResult, names: [String: String]) -> String {
        var line = "\(name(result.uuid, names)) brightness: \(result.original) → \(result.requested) of \(result.maximum)"
        if result.observed != result.requested { line += ", reads \(result.observed)" }
        return line
    }

    static func input(_ reading: DDCInputReading, names: [String: String]) -> String {
        "\(name(reading.uuid, names)) input: \(CLIText.input(reading.current))"
    }

    static func input(_ result: DDCInputSelection, names: [String: String]) -> String {
        var line = "\(name(result.uuid, names)) input: "
        switch result.outcome {
        case .alreadySelected:
            line += "\(CLIText.input(result.requested)), already selected"
        case .verified, .unverified:
            if let original = result.original { line += "\(CLIText.input(original)) → " }
            line += "\(CLIText.input(result.requested)), \(result.outcome == .verified ? "verified" : "unverified")"
            if let observed = result.observed, observed != result.requested { line += ", reads \(CLIText.input(observed))" }
        }
        if let detail = result.detail { line += "\n\(detail)" }
        return line
    }

    static func power(_ result: DDCPowerResult, names: [String: String]) -> String {
        var line = "\(name(result.uuid, names)) power: \(power(result.original))"
        switch result.outcome {
        case .reported: break
        case .alreadyReported: line += ", already reported"
        case .matchingReadback, .unverified:
            if let requested = result.requested { line += " → \(power(requested.code))" }
            line += result.outcome == .matchingReadback ? ", confirmed by readback" : ", unverified"
        }
        return line + "\n\(result.detail)"
    }

    /// MCCS VCP 0xD6 power mode.
    private static func power(_ code: UInt16) -> String {
        let name = [1: "on", 2: "standby", 3: "suspend", 4: "off", 5: "off (button)"][Int(code)] ?? "unknown"
        return "\(name) (\(String(format: "0x%02X", code)))"
    }
}
