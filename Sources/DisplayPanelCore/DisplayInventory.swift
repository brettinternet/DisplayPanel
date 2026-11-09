import Foundation
import AppKit
import CoreGraphics

public struct DisplayBounds: Codable, Equatable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.size.width; height = r.size.height }
}

public struct DisplayRecord: Codable, Equatable {
    public let index: Int
    public let id: UInt32
    public let uuid: String?
    public let name: String?
    public let active: Bool
    public let online: Bool
    public let asleep: Bool
    public let builtin: Bool
    public let main: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let bounds: DisplayBounds
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum DisplayInventory {
    public static func records() -> [DisplayRecord] {
        var onlineCount: UInt32 = 0
        var activeCount: UInt32 = 0
        var online = Array(repeating: CGDirectDisplayID(0), count: 32)
        var active = Array(repeating: CGDirectDisplayID(0), count: 32)
        CGGetOnlineDisplayList(UInt32(online.count), &online, &onlineCount)
        CGGetActiveDisplayList(UInt32(active.count), &active, &activeCount)
        let onlineIDs = Set(online.prefix(Int(onlineCount)))
        let activeIDs = Set(active.prefix(Int(activeCount)))
        let ids = onlineIDs.union(activeIDs).sorted()
        let screens = NSScreen.screens
        return ids.enumerated().map { offset, id in
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let uuid: String?
            if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, uuidRef) as String
            } else {
                uuid = nil
            }
            return DisplayRecord(
                index: offset + 1,
                id: id,
                uuid: uuid,
                name: screen?.localizedName ?? productName(id),
                active: activeIDs.contains(id),
                online: onlineIDs.contains(id),
                asleep: CGDisplayIsAsleep(id) != 0,
                builtin: CGDisplayIsBuiltin(id) != 0,
                main: CGDisplayIsMain(id) != 0,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                bounds: DisplayBounds(CGDisplayBounds(id)),
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id)
            )
        }
    }

    private static let metadata = try? CoreDisplayMetadata()

    /// CoreDisplay still names a display NSScreen omits, such as one hidden by mirroring.
    private static func productName(_ id: CGDirectDisplayID) -> String? {
        let info = metadata?.info(id)?.takeRetainedValue() as? [String: Any]
        guard let names = info?["DisplayProductName"] as? [String: String] else { return nil }
        return names[Locale.current.identifier] ?? names["en_US"] ?? names.values.first
    }

    public static func printRecords(_ records: [DisplayRecord], json: Bool) throws {
        if json {
            FileHandle.standardOutput.write(try CLIText.jsonData(records))
            print()
        } else {
            print(text(records))
        }
    }

    /// One row per display with every selector `--display` accepts.
    public static func text(_ records: [DisplayRecord]) -> String {
        guard !records.isEmpty else {
            return "No displays found (headless or no WindowServer context)."
        }
        func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
        let rows = records.map { d -> [String] in
            let size = "\(number(d.bounds.width))×\(number(d.bounds.height))"
            let pixels = Double(d.pixelWidth)
            let scaled = pixels == d.bounds.width ? size
                : pixels == 2 * d.bounds.width ? "\(size) @2x"
                : "\(size) (\(d.pixelWidth)×\(d.pixelHeight) px)"
            let state = [d.main ? "main" : nil, d.builtin ? "built-in" : nil, d.asleep ? "asleep" : nil,
                         d.online ? nil : "offline", d.online && !d.active ? "inactive" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return ["\(d.index)", "\(d.id)", d.name ?? "Display \(d.id)", d.uuid ?? "—", scaled,
                    "\(number(d.bounds.x)),\(number(d.bounds.y))", state]
        }
        return CLIText.table([["INDEX", "ID", "NAME", "UUID", "SIZE", "ORIGIN", "STATE"]] + rows)
    }
}
