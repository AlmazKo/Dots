import AppKit

// The menu bar item draws the active mode's glyph:
//
// - Only the monitors feeding the visible mode run; each calls onUpdate
//   when its (quantized) value changes.
// - refreshImage() captures the data to draw as a `Frame` and skips the
//   redraw when it equals the last one drawn.
// - We draw into our own CGContext and hand the CGImage to a CALayer:
//   setting NSStatusBarButton.image runs the button's whole layout and
//   display chain on every frame, about twice the cost.
// - Colours are NSColor.labelColor resolved under the button's
//   appearance, so the glyph follows a light or dark menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let cpuMonitor = CPUMonitor()
    private let tempMonitor = TempMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let gpuMonitor = GPUMonitor()
    private let latencyMonitor = LatencyMonitor()
    private let batteryMonitor = BatteryMonitor()

    private var statusItem: NSStatusItem!
    private var layout: Layout!
    private let renderLayer = CALayer()
    private var lastFrame: Frame?
    private var runningMode: AppSettings.Mode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CPUMonitor.isAppleSilicon else {
            let alert = NSAlert()
            alert.messageText = "Apple Silicon required"
            alert.informativeText = "dots reads per-cluster info that only Apple-designed chips expose. M1 or newer required."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        layout = Layout(coreCount: CPUMonitor.coreCount)
        statusItem = NSStatusBar.system.statusItem(withLength: layout.size.width + 8)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let host = PassthroughView(frame: NSRect(
                x: (button.bounds.width - layout.size.width) / 2,
                y: (button.bounds.height - layout.size.height) / 2,
                width: layout.size.width, height: layout.size.height
            ))
            host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            host.wantsLayer = true
            renderLayer.frame = host.bounds
            host.layer?.addSublayer(renderLayer)
            button.addSubview(host)
        }

        let redraw: () -> Void = { [weak self] in self?.refreshImage() }
        cpuMonitor.onUpdate = redraw
        tempMonitor.onUpdate = redraw
        memoryMonitor.onUpdate = redraw
        gpuMonitor.onUpdate = redraw
        latencyMonitor.onUpdate = redraw
        batteryMonitor.onUpdate = redraw
        settings.onChange = { [weak self] in self?.applySettings() }
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawAnyway() }
        }

        applySettings()
        LoginItem.ensureFirstRun()
        // Draw again once the item is in the menu bar: until then its
        // effectiveAppearance is .aqua even on a dark menu bar.
        DispatchQueue.main.async { [weak self] in self?.redrawAnyway() }
    }

    // Runs only the monitors feeding the visible mode: each one costs
    // wakeups, Latency a socket and GPU an IOAccelerator connection.
    // A refresh-rate change alone doesn't restart them, which would
    // wipe the GPU and Latency history.
    private func applySettings() {
        let interval = settings.interval.rawValue
        cpuMonitor.interval = interval
        memoryMonitor.interval = interval
        gpuMonitor.interval = interval

        let mode = settings.mode
        guard mode != runningMode else { return }
        runningMode = mode
        cpuMonitor.stop()
        tempMonitor.stop()
        memoryMonitor.stop()
        gpuMonitor.stop()
        latencyMonitor.stop()
        batteryMonitor.stop()
        switch mode {
        case .cpu:
            cpuMonitor.start()
            tempMonitor.start()
        case .memory: memoryMonitor.start()
        case .gpu: gpuMonitor.start()
        case .latency: latencyMonitor.start()
        case .battery: batteryMonitor.start()
        }
        statusItem.button?.toolTip = tooltip(for: mode)
        refreshImage()
    }

    private func tooltip(for mode: AppSettings.Mode) -> String {
        func percent(_ fraction: Double) -> String {
            fraction.formatted(.percent.precision(.fractionLength(0...1)))
        }
        switch mode {
        case .cpu:
            return """
                CPU load per core — one cell per logical core.
                Top row: performance cores. Lower rows: efficiency cores (with a hole).
                Turns red as the chip nears its throttling temperature.
                """
        case .memory:
            return """
                Memory used — each cell is \(percent(1 / Double(layout.memoryCells))) of RAM, filling bottom-up.
                Counts wired, active and compressed memory, like Activity Monitor.
                """
        case .gpu:
            return "GPU load — one bar per second, newest on the right."
        case .latency:
            return """
                Ping to \(LatencyMonitor.host) — one bar per second, newest on the right.
                Red bars are timeouts.
                """
        case .battery:
            return "Battery charge — each bar is \(percent(1 / Double(layout.batteryBars)))."
        }
    }

    private func currentFrame() -> Frame {
        switch settings.mode {
        case .cpu:
            // No tint up to 75 °C, fully red at 95 °C, where Apple
            // Silicon starts to throttle.
            let heat = min(1, max(0, (tempMonitor.maxCpuTemp - 75) / 20))
            return .cpu(loads: cpuMonitor.loads, heat: heat)
        case .memory: return .memory(memoryMonitor.used)
        case .gpu: return .gpu(Array(gpuMonitor.history.suffix(layout.gpuBars)))
        case .latency: return .latency(Array(latencyMonitor.history.suffix(layout.latencyBars)))
        case .battery: return .battery(batteryMonitor.level)
        }
    }

    // For changes the data doesn't capture: the appearance.
    private func redrawAnyway() {
        lastFrame = nil
        refreshImage()
    }

    private func refreshImage() {
        let frame = currentFrame()
        guard frame != lastFrame, let button = statusItem.button else { return }
        lastFrame = frame

        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let ctx = CGContext(
            data: nil,
            width: Int(layout.size.width * scale), height: Int(layout.size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        button.effectiveAppearance.performAsCurrentDrawingAppearance { layout.draw(frame) }
        NSGraphicsContext.restoreGraphicsState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no implicit cross-fade
        renderLayer.contentsScale = scale
        renderLayer.contents = ctx.makeImage()
        CATransaction.commit()
    }

    // MARK: - Menu

    // Left click opens Activity Monitor; right or ⌥-click shows the menu.
    @objc private func handleClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            showMenu()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        for mode in AppSettings.Mode.available {
            menu.addItem(item(mode.label, #selector(selectMode), value: mode, on: settings.mode == mode))
        }

        menu.addItem(.separator())
        // Apple renamed the tiers with M5: perflevel0/1 went from
        // "performance"/"efficiency" to "super"/"performance".
        let modern = [" M5", " M6", " M7", " M8", " M9"].contains { CPUMonitor.brand.contains($0) }
        let tiers = [
            (CPUMonitor.pCoreCount, modern ? "super" : "performance", false),
            (CPUMonitor.eCoreCount, modern ? "performance" : "efficiency", true),
        ]
        for (count, name, hole) in tiers where count > 0 {
            let row = NSMenuItem()
            row.view = CoreLegendRowView(label: "\(count) \(name) cores", hole: hole)
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let rate = NSMenuItem(title: "Refresh rate", action: nil, keyEquivalent: "")
        rate.submenu = NSMenu()
        for interval in AppSettings.Interval.allCases {
            rate.submenu?.addItem(item(interval.label, #selector(selectInterval),
                                       value: interval, on: settings.interval == interval))
        }
        menu.addItem(rate)

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLoginItem), value: nil, on: LoginItem.isEnabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit dots", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attach the menu for this click only, so a left click keeps
        // reaching handleClick.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, value: Any?, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = on ? .on : .off
        return item
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? AppSettings.Mode { settings.mode = mode }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        if let interval = sender.representedObject as? AppSettings.Interval { settings.interval = interval }
    }

    @objc private func toggleLoginItem() {
        LoginItem.toggle()
    }
}

// What a mode draws. Equal frames draw identically, so refreshImage
// skips them.
private enum Frame: Equatable {
    case cpu(loads: [Double], heat: Double)
    case memory(Double)
    case gpu([Double])
    case latency([Double?])
    case battery(Double)
}

// Geometry and drawing. Every mode draws into the same box, so
// switching modes never resizes the status item and shifts its
// neighbours: as wide as the CPU matrix (at least `minWidth`) and 20pt
// high — 40px on Retina, divisible by the latency scale's 5 and 10
// ticks, so every tick lands on a pixel. Charts, the memory grid and
// the battery pick how many bars or columns fill the width.
@MainActor
private struct Layout {
    static let minWidth: CGFloat = 35
    static let gap: CGFloat = 1  // between all cells and bars
    static let bar: CGFloat = 1
    static let coreCell: CGFloat = 5
    static let memoryCell: CGFloat = 3
    static let memoryRows = 5
    static let tickMinor: CGFloat = 1
    static let tickMajor: CGFloat = 3
    static let batteryPadding: CGFloat = 2
    static let batteryNipple: CGFloat = 2

    let size: NSSize
    let rows: Int, cols: Int  // CPU matrix
    let gpuBars: Int
    let latencyBars: Int
    let memoryCols: Int
    let batteryBars: Int
    var memoryCells: Int { memoryCols * Self.memoryRows }

    init(coreCount n: Int) {
        // At most 3 rows fit the menu bar. M5 Max's 18 cores give 6×3:
        // the top row holds its 6 P cores, CPUMonitor lists them first.
        rows = n <= 4 ? 1 : n <= 8 ? 2 : 3
        cols = (n + rows - 1) / rows
        let width = max(Self.span(cols, Self.coreCell), Self.minWidth)
        size = NSSize(width: width, height: 20)
        gpuBars = min(Self.fit(width, Self.bar), GPUMonitor.maxSamples)
        latencyBars = min(Self.fit(width - Self.gap - Self.tickMajor, Self.bar), LatencyMonitor.maxSamples)
        memoryCols = Self.fit(width, Self.memoryCell)
        batteryBars = Self.fit(width - 2 * Self.batteryPadding - Self.batteryNipple, Self.bar)
    }

    // Width of n items with gaps between them, and how many fit.
    private static func span(_ n: Int, _ item: CGFloat) -> CGFloat { CGFloat(n) * (item + gap) - gap }
    private static func fit(_ width: CGFloat, _ item: CGFloat) -> Int { Int((width + gap) / (item + gap)) }

    // Offset that centres `length` in `total`, on a Retina pixel.
    private static func centre(_ length: CGFloat, in total: CGFloat) -> CGFloat {
        (total - length).rounded(.down) / 2
    }

    // Level-meter alpha of cell i out of `count` showing `fraction`:
    // full cells solid, the boundary cell partial, the rest dim.
    private static func meterAlpha(_ i: Int, _ fraction: Double, _ count: Int) -> CGFloat {
        let filled = fraction * Double(count) - Double(i)
        return 0.12 + 0.88 * min(1, max(0, filled))
    }

    func draw(_ frame: Frame) {
        switch frame {
        case let .cpu(loads, heat): drawMatrix(loads, heat: heat)
        case let .memory(used): drawMemory(used)
        case let .gpu(history):
            let label = NSColor.labelColor.withAlphaComponent(0.85)
            drawBars(history, count: gpuBars, x: Self.centre(Self.span(gpuBars, Self.bar), in: size.width)) {
                (CGFloat($0) * size.height, label)
            }
        case let .latency(history): drawLatency(history)
        case let .battery(level): drawBattery(level)
        }
    }

    // Brightness is load. Row 0 is the top; lower-tier cores get a hole.
    // `heat` blends the cells towards red.
    private func drawMatrix(_ loads: [Double], heat: Double) {
        var color = NSColor.labelColor
        // labelColor is dynamic; resolve it to sRGB so it can be blended.
        if heat > 0, let label = color.usingColorSpace(.sRGB), let red = NSColor.systemRed.usingColorSpace(.sRGB) {
            color = label.blended(withFraction: CGFloat(heat), of: red) ?? color
        }
        let cell = Self.coreCell, step = cell + Self.gap
        let x0 = Self.centre(Self.span(cols, cell), in: size.width)
        let y0 = Self.centre(Self.span(rows, cell), in: size.height)
        for (i, load) in loads.prefix(rows * cols).enumerated() {
            let rect = NSRect(x: x0 + CGFloat(i % cols) * step, y: y0 + CGFloat(rows - 1 - i / cols) * step,
                              width: cell, height: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            if i >= CPUMonitor.pCoreCount { path.appendHole(in: rect) }
            color.withAlphaComponent(0.12 + 0.88 * load).setFill()
            path.fill()
        }
    }

    // Level meter filling the bottom row first, left to right.
    private func drawMemory(_ used: Double) {
        let cell = Self.memoryCell, step = cell + Self.gap
        let x0 = Self.centre(Self.span(memoryCols, cell), in: size.width)
        let y0 = Self.centre(Self.span(Self.memoryRows, cell), in: size.height)
        for i in 0..<memoryCells {
            let rect = NSRect(x: x0 + CGFloat(i % memoryCols) * step, y: y0 + CGFloat(i / memoryCols) * step,
                              width: cell, height: cell)
            NSColor.labelColor.withAlphaComponent(Self.meterAlpha(i, used, memoryCells)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
        }
    }

    // Bars with a tick scale on the right. The scale steps through
    // 50/100/200/500/1000 ms with 5 or 10 ticks — whole pixels of the
    // 40px box — so bars never clip; ticks at 100 ms multiples are
    // longer. A timeout (nil) is a full-height red bar.
    private func drawLatency(_ history: [Double?]) {
        let peak = history.compactMap { $0 }.max() ?? 0
        let (scale, step): (Double, Int) =
            peak < 50 ? (50, 10) : peak < 100 ? (100, 10) : peak < 200 ? (200, 20) : peak < 500 ? (500, 50) : (1000, 100)
        let barsWidth = Self.span(latencyBars, Self.bar)
        let x0 = Self.centre(barsWidth + Self.gap + Self.tickMajor, in: size.width)
        let label = NSColor.labelColor.withAlphaComponent(0.85)
        let red = NSColor.systemRed.withAlphaComponent(0.85)
        drawBars(history, count: latencyBars, x: x0) { ms in
            guard let ms else { return (size.height, red) }
            return (CGFloat(min(1, ms / scale)) * size.height, label)
        }
        for ms in stride(from: step, through: Int(scale), by: step) {
            let major = ms % 100 == 0
            let y = min(size.height - 1, CGFloat(Double(ms) / scale) * size.height)  // keep the top tick inside
            NSColor.labelColor.withAlphaComponent(major ? 0.6 : 0.3).setFill()
            NSRect(x: x0 + barsWidth + Self.gap, y: y, width: major ? Self.tickMajor : Self.tickMinor, height: 1).fill()
        }
    }

    // Outline with a nipple on the right; bars fill left to right.
    private func drawBattery(_ level: Double) {
        let pad = Self.batteryPadding
        let bodyWidth = Self.span(batteryBars, Self.bar) + 2 * pad
        let body = NSRect(x: Self.centre(bodyWidth + Self.batteryNipple, in: size.width), y: 0,
                          width: bodyWidth, height: size.height)
        let outline = NSColor.labelColor.withAlphaComponent(0.7)
        outline.setStroke()
        outline.setFill()
        NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        NSBezierPath(roundedRect: NSRect(x: body.maxX, y: body.midY - 3, width: Self.batteryNipple, height: 6),
                     xRadius: 1, yRadius: 1).fill()
        for i in 0..<batteryBars {
            NSColor.labelColor.withAlphaComponent(Self.meterAlpha(i, level, batteryBars)).setFill()
            NSRect(x: body.minX + pad + CGFloat(i) * (Self.bar + Self.gap), y: pad,
                   width: Self.bar, height: size.height - 2 * pad).fill()
        }
    }

    // One bar per value, newest on the right; slots not yet sampled show
    // a dim 1pt baseline.
    private func drawBars<T>(_ values: [T], count: Int, x x0: CGFloat,
                             style: (T) -> (height: CGFloat, color: NSColor)) {
        let empty = count - values.count
        for i in 0..<count {
            let (height, color) = i < empty
                ? (1, NSColor.labelColor.withAlphaComponent(0.12))
                : style(values[i - empty])
            color.setFill()
            NSRect(x: x0 + CGFloat(i) * (Self.bar + Self.gap), y: 0, width: Self.bar, height: max(1, height)).fill()
        }
    }
}

// Menu legend row: the matrix cell glyph, enlarged, and its tier name.
private final class CoreLegendRowView: NSView {
    private let label: String
    private let hole: Bool

    init(label: String, hole: Bool) {
        self.label = label
        self.hole = hole
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSRect(x: 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let path = NSBezierPath(roundedRect: icon, xRadius: 2, yRadius: 2)
        if hole { path.appendHole(in: icon) }
        NSColor.labelColor.setFill()
        path.fill()

        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ])
        text.draw(at: NSPoint(x: icon.maxX + 10, y: (bounds.height - text.size().height) / 2))
    }
}

// Click-through host for the render layer, so clicks reach the button.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSBezierPath {
    // The round hole marking lower-tier cores.
    func appendHole(in rect: NSRect) {
        let d = rect.width * 0.4
        append(NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)))
        windingRule = .evenOdd
    }
}
