import Foundation

// User-facing settings persisted to UserDefaults. Plain class with a
// single onChange callback - we don't need ObservableObject/@Published
// since AppDelegate is the only consumer.
@MainActor
final class AppSettings {
    enum Interval: Double, CaseIterable {
        case fast = 0.1
        case medium = 0.2
        case slow = 0.5
        case verySlow = 1.0

        var label: String {
            switch self {
            case .fast: return "0.1s (10 Hz)"
            case .medium: return "0.2s (5 Hz)"
            case .slow: return "0.5s (2 Hz)"
            case .verySlow: return "1s (1 Hz)"
            }
        }
    }

    enum Mode: String, CaseIterable {
        case cpu
        case memory
        case gpu
        case latency
        case battery

        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .gpu: return "GPU"
            case .latency: return "Latency"
            case .battery: return "Battery"
            }
        }

        // Modes this Mac can show, in menu order.
        static let available: [Mode] = allCases.filter {
            $0 != .battery || BatteryMonitor.hasBattery
        }
    }

    private static let intervalKey = "interval"
    private static let modeKey = "mode"

    var interval: Interval {
        didSet {
            UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
            onChange?()
        }
    }

    var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        let storedInterval = defaults.object(forKey: Self.intervalKey) as? Double
        self.interval = storedInterval.flatMap(Interval.init(rawValue:)) ?? .fast
        let storedMode = defaults.string(forKey: Self.modeKey)
        self.mode = storedMode.flatMap(Mode.init(rawValue:))
            .flatMap { Mode.available.contains($0) ? $0 : nil } ?? .cpu
    }
}
