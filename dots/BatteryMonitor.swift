import Foundation
import IOKit.ps

// Internal battery charge (0...1) via IOKit Power Sources. No polling:
// powerd notifies on every power-source change, so the mode costs no
// wakeups in between.
@MainActor
final class BatteryMonitor {
    // Desktop Macs have no internal battery; the mode is hidden there.
    nonisolated static var hasBattery: Bool { readLevel() != nil }

    private(set) var level: Double = 0
    var onUpdate: (() -> Void)?

    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        sample()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.sample() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }

    func stop() {
        if let source { CFRunLoopSourceInvalidate(source) }
        source = nil
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    private func sample() {
        let next = Self.readLevel() ?? 0
        guard next != level else { return }
        level = next
        onUpdate?()
    }

    nonisolated private static func readLevel() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 else { continue }
            return min(1, max(0, Double(capacity) / Double(maxCapacity)))
        }
        return nil
    }
}
