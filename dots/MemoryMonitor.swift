import Foundation
import Darwin

// Used memory = (wired + active + compressed) / total — the same
// definition as Activity Monitor's "Memory Used". Floored to 1% so the
// redraw is skipped on equality.
@MainActor
final class MemoryMonitor {
    private(set) var used: Double = 0
    var onUpdate: (() -> Void)?
    var interval: TimeInterval {
        get { ticker.interval }
        set { ticker.interval = newValue }
    }

    private lazy var ticker = Ticker(interval: 0.2) { [weak self] in self?.sample() }

    func start() {
        sample()
        ticker.start()
    }

    func stop() {
        ticker.stop()
    }

    private func sample() {
        let next = (Self.usedFraction() * 100).rounded(.down) / 100
        guard next != used else { return }
        used = next
        onUpdate?()
    }

    nonisolated private static func usedFraction() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS, total > 0 else { return 0 }
        let pages = UInt64(stats.wire_count) + UInt64(stats.active_count) + UInt64(stats.compressor_page_count)
        return min(1, Double(pages * UInt64(getpagesize())) / Double(total))
    }
}
