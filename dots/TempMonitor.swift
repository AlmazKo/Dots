import Foundation
import IOKit

// Hottest CPU cluster temperature via the private IOHIDEventSystem SPI
// — the approach Stats and most temperature tools use, since public
// APIs expose no Apple Silicon thermal data. It feeds the CPU mode's
// red tint; if the SPI ever fails, maxCpuTemp stays 0 and there's
// simply no tint.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: UInt64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ property: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15
private let kIOHIDEventFieldTemperatureLevel = Int32(kIOHIDEventTypeTemperature << 16)

@MainActor
final class TempMonitor {
    private(set) var maxCpuTemp: Double = 0  // °C
    var onUpdate: (() -> Void)?

    private lazy var ticker = Ticker(interval: 1) { [weak self] in self?.sample() }
    private var client: AnyObject?
    // CPU sensors, matched by name once rather than every second.
    private var sensors: [AnyObject] = []

    func start() {
        if client == nil, let raw = IOHIDEventSystemClientCreate(nil) {
            let c = raw.takeRetainedValue()
            // Apple vendor usage page 0xff00, usage 5: temperature sensors.
            _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            client = c
        }
        sample()
        ticker.start()
    }

    func stop() {
        ticker.stop()
    }

    private func sample() {
        if sensors.isEmpty { sensors = matchSensors() }
        var hottest: Double = 0
        for sensor in sensors {
            guard let event = IOHIDServiceClientCopyEvent(sensor, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let t = IOHIDEventGetFloatValue(event.takeRetainedValue(), kIOHIDEventFieldTemperatureLevel)
            // Unwired sensors report nonsense like -9200 °C.
            if t > 0, t < 150 { hottest = max(hottest, t) }
        }
        // Ignore sub-half-degree jitter so it doesn't force redraws.
        guard abs(hottest - maxCpuTemp) >= 0.5 else { return }
        maxCpuTemp = hottest
        onUpdate?()
    }

    // M1/M2 name their cluster sensors "pACC…"/"eACC…", M3+ use CPU die
    // diodes "PMU tdie…" ("PMU tdev…" are unconnected, "PMU tcal" is a
    // calibration reference).
    private func matchSensors() -> [AnyObject] {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() else { return [] }
        return (services as [AnyObject]).filter { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String else { return false }
            return name.hasPrefix("pACC") || name.hasPrefix("eACC") || name.hasPrefix("PMU tdie")
        }
    }
}
