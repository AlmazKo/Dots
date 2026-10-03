import Foundation
import Darwin

// Per-core CPU load via host_processor_info: the busy share of each
// core's tick counters since the previous sample.
@MainActor
final class CPUMonitor {
    nonisolated static let coreCount = sysctlInt("hw.logicalcpu") ?? 1
    // perflevel0 is the fastest tier: P cores ("super" cores on M5+).
    nonisolated static let pCoreCount = sysctlInt("hw.perflevel0.logicalcpu") ?? coreCount
    nonisolated static let eCoreCount = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    nonisolated static let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
    nonisolated static let brand: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()

    // P cores first, each floored to a 10% bucket: an idle core stays
    // exactly 0, so the redraw is skipped on equality, and a 5pt cell
    // can't show finer steps anyway.
    private(set) var loads: [Double] = []
    var onUpdate: (() -> Void)?
    var interval: TimeInterval {
        get { ticker.interval }
        set { ticker.interval = newValue }
    }

    private struct Ticks { var user, system, idle, nice: UInt32 }
    private var prev: [Ticks] = []
    private lazy var ticker = Ticker(interval: 0.2) { [weak self] in self?.sample() }

    func start() {
        loads = Array(repeating: 0, count: Self.coreCount)
        sample()
        ticker.start()
    }

    // Drop the old ticks too, or the first sample after a pause would
    // show the average over the whole pause.
    func stop() {
        ticker.stop()
        prev.removeAll()
    }

    private func sample() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let ticks = info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) { ptr in
            (0..<Int(cpuCount)).map { i in
                let t = ptr[i].cpu_ticks
                return Ticks(user: t.0, system: t.1, idle: t.2, nice: t.3)
            }
        }
        defer { prev = ticks }
        guard prev.count == ticks.count else { return }

        // The counters are UInt32 and wrap after months of uptime;
        // wrapping subtraction keeps the deltas right.
        let raw = zip(ticks, prev).map { s, p -> Double in
            let busy = Double(s.user &- p.user) + Double(s.system &- p.system) + Double(s.nice &- p.nice)
            let total = busy + Double(s.idle &- p.idle)
            return total > 0 ? busy / total : 0
        }
        // Apple Silicon numbers the E cores first.
        let e = Self.eCoreCount < raw.count ? Self.eCoreCount : 0
        let next = (raw.dropFirst(e) + raw.prefix(e)).map { ($0 * 10).rounded(.down) / 10 }
        guard next != loads else { return }
        loads = next
        onUpdate?()
    }

    nonisolated private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}
