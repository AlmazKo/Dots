import Foundation
import Darwin

// ICMP echo to www.google.com once a second, through the unprivileged
// SOCK_DGRAM/IPPROTO_ICMP socket macOS offers since 10.12 — no root,
// no entitlements. The kernel adds the IP header and routes replies to
// our socket; we build the ICMP echo request (RFC 792) ourselves.
//
// `history` holds the last `maxSamples` round-trips in ms; `nil` is a
// timeout or failure, drawn as a red bar.
@MainActor
final class LatencyMonitor {
    nonisolated static let maxSamples = 64
    nonisolated static let host = "www.google.com"
    nonisolated fileprivate static let timeout: TimeInterval = 0.95

    private(set) var history: [Double?] = []
    var onUpdate: (() -> Void)?

    private lazy var ticker = Ticker(interval: 1) { [weak self] in self?.tick() }
    // DNS and the blocking socket calls run here, never on the main
    // thread: getaddrinfo can stall for seconds on a flaky network.
    private let queue = DispatchQueue(label: "dots.latency")
    private let pinger = Pinger()
    private let identifier = UInt16(truncatingIfNeeded: getpid())
    private var sequence: UInt16 = 0
    // Bumped on stop() so a ping still in flight can't land in the
    // history of a later session.
    private var generation = 0
    // While a ping is out (e.g. stuck in DNS), further ticks are
    // skipped instead of piling up on the serial queue.
    private var inFlight = false

    func start() {
        ticker.start()
        tick()
    }

    func stop() {
        ticker.stop()
        generation &+= 1
        inFlight = false
        history.removeAll()
        let pinger = self.pinger
        queue.async { pinger.close() }
    }

    private func tick() {
        guard !inFlight else { return }
        inFlight = true
        let (pinger, identifier, seq, gen) = (self.pinger, self.identifier, sequence, generation)
        sequence &+= 1
        queue.async { [weak self] in
            let ms = pinger.ping(identifier: identifier, sequence: seq)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.inFlight = false
                    self.history.append(ms)
                    if self.history.count > Self.maxSamples { self.history.removeFirst() }
                    self.onUpdate?()
                }
            }
        }
    }
}

// Socket and resolved address, touched only on LatencyMonitor's serial
// queue — hence @unchecked Sendable.
private final class Pinger: @unchecked Sendable {
    private var sock: Int32 = -1
    private var addr: sockaddr_in?

    // Round-trip in ms, or nil on failure / timeout. A failure drops the
    // address, so the next ping re-resolves: the network, and with it
    // the nearest Google edge, may have changed — and a monitor started
    // offline recovers on its own.
    func ping(identifier: UInt16, sequence: UInt16) -> Double? {
        if sock < 0 { sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) }
        if addr == nil { addr = Self.resolve(LatencyMonitor.host) }
        guard sock >= 0, var dst = addr else { return nil }
        let ms = Self.echo(sock: sock, to: &dst, identifier: identifier, sequence: sequence)
        if ms == nil { addr = nil }
        return ms
    }

    func close() {
        if sock >= 0 { Darwin.close(sock) }
        sock = -1
        addr = nil
    }

    deinit { close() }

    private static func resolve(_ host: String) -> sockaddr_in? {
        // AF_INET only: socktype/protocol hints confuse getaddrinfo for
        // ICMP, which has no notion of ports.
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = res.pointee.ai_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    // Sends one echo request and waits up to `timeout` for the reply with
    // our sequence number; late replies to earlier pings are skipped.
    private static func echo(sock: Int32, to addr: inout sockaddr_in,
                             identifier: UInt16, sequence: UInt16) -> Double? {
        let packet = echoRequest(identifier: identifier, sequence: sequence)
        let start = Date()
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return nil }

        let deadline = start.addingTimeInterval(LatencyMonitor.timeout)
        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32(remaining.truncatingRemainder(dividingBy: 1) * 1_000_000))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let n = recv(sock, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            // The datagram may or may not start with the IPv4 header.
            let icmp = n > 20 && buf[0] >> 4 == 4 ? Int(buf[0] & 0x0F) * 4 : 0
            guard n - icmp >= 8, buf[icmp] == 0 else { continue }  // type 0: echo reply
            if UInt16(buf[icmp + 6]) << 8 | UInt16(buf[icmp + 7]) == sequence {
                return -start.timeIntervalSinceNow * 1000
            }
        }
    }

    // 8-byte ICMP header + 8 zero bytes of payload. The kernel may
    // rewrite the identifier (it demuxes replies by it), but the
    // sequence number survives the round trip.
    private static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 8  // echo request
        p[4] = UInt8(identifier >> 8)
        p[5] = UInt8(identifier & 0xFF)
        p[6] = UInt8(sequence >> 8)
        p[7] = UInt8(sequence & 0xFF)
        // RFC 1071: one's complement of the one's-complement sum of the
        // 16-bit words, computed with the checksum field zeroed.
        var sum: UInt32 = 0
        for i in stride(from: 0, to: p.count, by: 2) {
            sum += UInt32(p[i]) << 8 | UInt32(p[i + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        p[2] = UInt8(checksum >> 8)
        p[3] = UInt8(checksum & 0xFF)
        return p
    }
}
