import Foundation
import IOKit

// GPU utilization from IOAccelerator's PerformanceStatistics ("Device
// Utilization %"). Apple Silicon exposes no per-core GPU stats without
// the private IOReport framework, so this is a single value.
//
// Samples taken at the user's rate are averaged per second; `history`
// gets one entry per second (floored to 10%) and onUpdate fires only
// then — redrawing a slow signal 10× a second would be wasted work.
@MainActor
final class GPUMonitor {
    nonisolated static let maxSamples = 64

    private(set) var history: [Double] = []
    var onUpdate: (() -> Void)?
    var interval: TimeInterval {
        get { ticker.interval }
        set { ticker.interval = newValue }
    }

    private lazy var ticker = Ticker(interval: 0.2) { [weak self] in self?.sample() }
    private var service: io_service_t = 0
    private var secondStart = Date()
    private var sum: Double = 0
    private var count = 0

    func start() {
        guard service == 0 else { return }
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        secondStart = Date()
        sample()
        ticker.start()
    }

    func stop() {
        ticker.stop()
        if service != 0 { IOObjectRelease(service) }
        service = 0
        history.removeAll()
        sum = 0
        count = 0
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    private func sample() {
        guard service != 0 else { return }
        var advanced = false
        while Date().timeIntervalSince(secondStart) >= 1 {
            let average = count > 0 ? sum / Double(count) : 0
            history.append((average * 10).rounded(.down) / 10)
            if history.count > Self.maxSamples { history.removeFirst() }
            secondStart += 1
            sum = 0
            count = 0
            advanced = true
        }
        sum += utilization()
        count += 1
        if advanced { onUpdate?() }
    }

    private func utilization() -> Double {
        // NSDictionary, not [String: Any]: no need to bridge the whole
        // statistics dictionary for one value.
        guard let stats = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSDictionary else { return 0 }
        let value = (stats["Device Utilization %"] ?? stats["Renderer Utilization %"]) as? NSNumber
        return min(1, max(0, (value?.doubleValue ?? 0) / 100))
    }
}
