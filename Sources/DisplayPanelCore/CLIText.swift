import Foundation

/// Layout for human CLI output; `--json` stays the machine interface.
public enum CLIText {
    /// Left-aligned columns two spaces apart, without trailing spaces.
    public static func table(_ rows: [[String]], indent: String = "") -> String {
        var widths: [Int] = []
        for row in rows {
            for (column, cell) in row.enumerated() {
                if column == widths.count { widths.append(0) }
                widths[column] = max(widths[column], cell.count)
            }
        }
        return rows.map { row in
            var line = indent + row.enumerated().map { column, cell in
                cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            while line.last == " " { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    /// "1h 5m", "4m 5s" or "45s", as the app shows countdowns.
    public static func countdown(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    /// "HDMI 1 (0x11)"
    public static func input(_ code: UInt8) -> String {
        let name = MonitorInput.name(code)
        return name.hasPrefix("Input 0x") ? name : "\(name) (\(String(format: "0x%02X", code)))"
    }
}
