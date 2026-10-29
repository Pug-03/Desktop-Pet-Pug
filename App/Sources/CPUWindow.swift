import AppKit
import Darwin

/// "CPU usage": live graphs of how hard the whole Mac and Pug himself are working, sampled
/// once a second over the last two minutes. It only measures while the window is open.
final class CPUWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let graph = CPUGraph()
    private var timer: Timer?
    private var lastHost: [UInt32]?
    private var lastSelf: (cpu: Double, wall: Double)?

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = L.t("CPU usage")
        window.contentView = graph
        window.minSize = CGSize(width: 380, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        sample()
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        lastHost = nil
        lastSelf = nil
        graph.mac.removeAll()
        graph.pug.removeAll()
    }

    private func sample() {
        if let mac = macPercent() { graph.mac.append(mac) }
        if let pug = pugPercent() { graph.pug.append(pug) }
        for k in [\CPUGraph.mac, \CPUGraph.pug] where graph[keyPath: k].count > CPUGraph.span {
            graph[keyPath: k].removeFirst(graph[keyPath: k].count - CPUGraph.span)
        }
        graph.needsDisplay = true
    }

    /// Share of all cores busy since the last sample (0-100).
    private func macPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]  // user, system, idle, nice
        defer { lastHost = ticks }
        guard let last = lastHost else { return nil }
        let d = zip(ticks, last).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : nil
    }

    /// Pug's own CPU time since the last sample, as a share of one core (0-100).
    private func pugPercent() -> Double? {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return nil }
        let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        let wall = CACurrentMediaTime()
        defer { lastSelf = (cpu, wall) }
        guard let last = lastSelf, wall > last.wall else { return nil }
        return min(100, (cpu - last.cpu) / (wall - last.wall) * 100)
    }
}

/// Two line charts, the whole Mac on top (0-100%) and Pug below (scaled to his own peak).
final class CPUGraph: NSView {
    static let span = 120  // samples kept: two minutes
    var mac: [Double] = []
    var pug: [Double] = []

    private let ink = NSColor.labelColor
    private let muted = NSColor.secondaryLabelColor
    private let grid = NSColor.separatorColor
    private let macColor = NSColor(calibratedRed: 0.31, green: 0.64, blue: 0.89, alpha: 1)
    private let pugColor = NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.64, alpha: 1)

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let pad: CGFloat = 18
        let h = (bounds.height - pad * 3) / 2
        chart(CGRect(x: pad, y: pad, width: bounds.width - pad * 2, height: h),
              title: L.t("Whole Mac"), note: L.t("all cores"), values: mac, top: 100, color: macColor)
        let peak = pug.max() ?? 0
        let top = [2.0, 5, 10, 25, 50, 100].first { $0 >= peak * 1.2 } ?? 100
        chart(CGRect(x: pad, y: pad * 2 + h, width: bounds.width - pad * 2, height: h),
              title: L.t("Pug"), note: L.t("share of one core"), values: pug, top: top, color: pugColor)
    }

    private func chart(_ r: CGRect, title: String, note: String, values: [Double], top: Double, color: NSColor) {
        let head = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 11)
        let big = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        (title as NSString).draw(at: CGPoint(x: r.minX, y: r.minY), withAttributes: [.font: head, .foregroundColor: ink])
        let tw = (title as NSString).size(withAttributes: [.font: head]).width
        (note as NSString).draw(at: CGPoint(x: r.minX + tw + 8, y: r.minY + 2), withAttributes: [.font: small, .foregroundColor: muted])

        let now = values.last.map { String(format: $0 < 10 ? "%.1f%%" : "%.0f%%", $0) } ?? "–"
        let avg = values.isEmpty ? "" : L.t("average") + " " + String(format: "%.1f%%", values.reduce(0, +) / Double(values.count))
        let nw = (now as NSString).size(withAttributes: [.font: big]).width
        (now as NSString).draw(at: CGPoint(x: r.maxX - nw, y: r.minY - 6), withAttributes: [.font: big, .foregroundColor: color])
        let aw = (avg as NSString).size(withAttributes: [.font: small]).width
        (avg as NSString).draw(at: CGPoint(x: r.maxX - nw - aw - 10, y: r.minY + 2), withAttributes: [.font: small, .foregroundColor: muted])

        // plot area, with the scale on the left: 0, half, top
        let label: CGFloat = 34
        let plot = CGRect(x: r.minX + label, y: r.minY + 28, width: r.width - label, height: r.height - 44)
        for (i, frac) in [1.0, 0.5, 0.0].enumerated() {
            let y = plot.minY + plot.height * CGFloat(1 - frac)
            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y)); line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = i == 2 ? 1 : 0.5
            line.stroke()
            let v = top * frac
            let s = (v < 10 && v != 0 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + "%"
            let sw = (s as NSString).size(withAttributes: [.font: small]).width
            (s as NSString).draw(at: CGPoint(x: plot.minX - sw - 6, y: y - 7), withAttributes: [.font: small, .foregroundColor: muted])
        }
        let ago = L.t("2 min ago"), nowLabel = L.t("now")
        (ago as NSString).draw(at: CGPoint(x: plot.minX, y: plot.maxY + 2), withAttributes: [.font: small, .foregroundColor: muted])
        let nlw = (nowLabel as NSString).size(withAttributes: [.font: small]).width
        (nowLabel as NSString).draw(at: CGPoint(x: plot.maxX - nlw, y: plot.maxY + 2), withAttributes: [.font: small, .foregroundColor: muted])

        guard values.count > 1 else { return }
        let step = plot.width / CGFloat(CPUGraph.span - 1)
        let x0 = plot.maxX - step * CGFloat(values.count - 1)  // the newest sample sits at the right edge
        let pts = values.enumerated().map { i, v in
            CGPoint(x: x0 + step * CGFloat(i), y: plot.maxY - plot.height * CGFloat(min(v, top) / top))
        }
        let area = NSBezierPath()
        area.move(to: CGPoint(x: pts[0].x, y: plot.maxY))
        pts.forEach { area.line(to: $0) }
        area.line(to: CGPoint(x: pts[pts.count - 1].x, y: plot.maxY))
        area.close()
        color.withAlphaComponent(0.18).setFill()
        area.fill()
        let line = NSBezierPath()
        line.move(to: pts[0])
        pts.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 2
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
        if let p = pts.last {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()
        }
    }
}
