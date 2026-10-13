import CoreGraphics
import Foundation
import OSLog

private let reconfigurationLogger = Logger(subsystem: "com.brettinternet.panelctl", category: "display-reconfiguration")

/// CoreGraphics can call back inside our synchronous writer or on another event
/// thread. Stamp at receipt, not when the main actor eventually handles it.
final class DisplayReconfigurationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var writing = false
    private var quietUntil: TimeInterval = 0
    private var registered = false
    private var handler: (@MainActor (UInt32, CGDisplayChangeSummaryFlags, Bool) -> Void)?

    @MainActor
    func start(_ handler: @escaping @MainActor (UInt32, CGDisplayChangeSummaryFlags, Bool) -> Void) {
        self.handler = handler
        let result = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        registered = result == .success
        if !registered { reconfigurationLogger.error("Callback registration failed: \(result.rawValue)") }
    }

    @MainActor
    func stop() {
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
        handler = nil
    }

    func operationChanged(busy: Bool) {
        lock.lock()
        generation &+= 1
        writing = busy
        // Trailing driver notifications belong to the operation too. Beyond
        // this quiet period, identical verified topology is a core no-op.
        quietUntil = ProcessInfo.processInfo.systemUptime + 1
        lock.unlock()
    }

    private func stamp() -> (UInt64, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (generation, writing || ProcessInfo.processInfo.systemUptime < quietUntil)
    }

    func receive(display: UInt32, flags: CGDisplayChangeSummaryFlags) {
        let received = stamp()
        reconfigurationLogger.info("display=\(display) flags=\(flags.rawValue) ownOperation=\(received.1)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = self.stamp()
            self.handler?(display, flags, received.1 || current.1 || received.0 != current.0)
        }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard let context else { return }
        Unmanaged<DisplayReconfigurationEvents>.fromOpaque(context).takeUnretainedValue()
            .receive(display: display, flags: flags)
    }
}
