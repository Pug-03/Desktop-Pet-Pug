import AppKit
import Darwin
import WebKit

/// "CPU usage": live graphs of how hard the whole Mac and Pug himself are working, one reading
/// a second over the last two minutes, drawn in the schedule's pixel style (cpu.html). It
/// only measures while the window is open.
final class CPUWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let window: NSWindow
    let web: WKWebView
    private var avatar: String
    private var loaded = false
    private var timer: Timer?
    private var lastHost: [UInt32]?
    private var lastSelf: (cpu: Double, wall: Double)?

    init(avatar: String) {
        self.avatar = avatar
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.LANG = '\(Settings.language)'",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 560), configuration: config)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = L.t("CPU usage")
        window.contentView = web
        window.minSize = CGSize(width: 460, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        if let page = Bundle.main.url(forResource: "cpu", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show() {
        if timer == nil {
            sample()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        web.evaluateJavaScript("CPU.reset('\(avatar)')", completionHandler: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        lastHost = nil
        lastSelf = nil
        if loaded { web.evaluateJavaScript("CPU.reset()", completionHandler: nil) }
    }

    private func sample() {
        let mac = macPercent(), pug = pugPercent()
        guard loaded else { return }
        let js = { (v: Double?) in v.map { String(format: "%.2f", $0) } ?? "null" }
        web.evaluateJavaScript("CPU.push(\(js(mac)), \(js(pug)))", completionHandler: nil)
    }

    /// Share of all cores busy since the last reading (0-100).
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

    /// Pug's own CPU time since the last reading, as a share of one core (0-100).
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
