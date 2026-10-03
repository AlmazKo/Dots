import Foundation

// Repeating main-run-loop timer that can be stopped and re-timed. The
// 10% tolerance lets the kernel coalesce our wakeups with others'.
@MainActor
final class Ticker {
    var interval: TimeInterval {
        didSet { if timer != nil, interval != oldValue { stop(); start() } }
    }
    private let action: () -> Void
    private var timer: Timer?

    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.action() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
