import AppKit
import WebKit

/// One entry in the monthly schedule.
struct ScheduleEvent: Codable {
    var id: String
    var date: String      // yyyy-MM-dd, the first day (the reminder goes off on it)
    var end: String?      // last day, for plans over several days
    var time: String      // HH:mm
    var title: String
    var detail: String
    var notified: Bool
    var repeats: String?  // "week", "month" or "year"; repeating plans are one day long
    var ahead: Int?       // remind this many minutes early
    var lastNotified: String?  // the day of the last occurrence he reminded about (repeating plans)
    var countdown: Bool?  // he says how many days are left, once a day

    /// The day it next happens, today or later (nil when it's over).
    func nextDay(from today: String) -> String? {
        guard let unit: Calendar.Component = ["week": .weekOfYear, "month": .month, "year": .year][repeats ?? ""] else {
            return date >= today ? date : nil
        }
        let f = ScheduleStore.parser
        guard let first = f.date(from: "\(date) 00:00") else { return nil }
        for k in 0..<2000 {
            guard let d = f.calendar.date(byAdding: unit, value: k, to: first) else { return nil }
            let day = String(f.string(from: d).prefix(10))
            if day >= today { return day }
        }
        return nil
    }

    /// The occurrence that is due by `now` (its day, and when to remind), if any is waiting.
    func pending(at now: Date) -> (day: String, at: Date)? {
        let early = TimeInterval((ahead ?? 0) * 60)
        guard let first = ScheduleStore.parser.date(from: "\(date) \(time)") else { return nil }
        guard let unit: Calendar.Component = ["week": .weekOfYear, "month": .month, "year": .year][repeats ?? ""] else {
            return notified || first.addingTimeInterval(-early) > now ? nil : (date, first.addingTimeInterval(-early))
        }
        // the latest occurrence whose reminder time has passed; counting from the first keeps the 31st and Feb 29 right
        let cal = ScheduleStore.parser.calendar!
        var latest: Date?
        for k in 0... {
            guard let d = cal.date(byAdding: unit, value: k, to: first), d.addingTimeInterval(-early) <= now else { break }
            latest = d
        }
        guard let d = latest else { return nil }
        let day = String(ScheduleStore.parser.string(from: d).prefix(10))
        return day == lastNotified ? nil : (day, d.addingTimeInterval(-early))
    }
}

/// Events saved in ~/Library/Application Support/Pug/schedule.json.
final class ScheduleStore {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    let url: URL
    private(set) var events: [ScheduleEvent] = []

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pug/schedule.json")
        if let data = try? Data(contentsOf: self.url) {
            if let list = try? JSONDecoder().decode([ScheduleEvent].self, from: data) {
                events = list
            } else {
                // unreadable: keep it aside so the next save can't wipe her plans
                let bad = self.url.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: self.url, to: bad)
            }
        }
    }

    func replace(_ list: [ScheduleEvent]) {
        events = list
        save()
    }

    func markNotified(_ id: String, day: String) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        if events[i].repeats == nil { events[i].notified = true } else { events[i].lastNotified = day }
        save()
    }

    func count(on date: String) -> Int { events.filter { $0.date <= date && ($0.end ?? $0.date) >= date }.count }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(events) { try? data.write(to: url, options: .atomic) }
    }

    /// Plans whose reminder time has come and that have not been announced yet, with the
    /// occurrence's day and when the reminder was due.
    func due(at now: Date) -> [(event: ScheduleEvent, day: String, at: Date)] {
        events.compactMap { e in e.pending(at: now).map { (e, $0.day, $0.at) } }
            .sorted { $0.at < $1.at }
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// The pixel-styled monthly schedule window (an HTML page in a web view).
final class ScheduleWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let web: WKWebView
    private let store: ScheduleStore
    private var avatar: String
    private var loaded = false
    var onAdded: ((String) -> Void)?
    var onLoaded: (() -> Void)?

    init(store: ScheduleStore, avatar: String) {
        self.store = store
        self.avatar = avatar
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 760), configuration: config)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "pug")
        config.userContentController.addUserScript(WKUserScript(source: "window.LANG = '\(Settings.language)'",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = L.t("Pug's Schedule")
        window.contentView = web
        window.minSize = CGSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        if let page = Bundle.main.url(forResource: "schedule", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show(avatar: String) {
        self.avatar = avatar
        push()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Send the current events to the page.
    func push() {
        guard loaded,
              let data = try? JSONEncoder().encode(store.events),
              let json = String(data: data, encoding: .utf8) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        web.evaluateJavaScript("PUG.load(\(json), '\(avatar)', '\(today)')", completionHandler: nil)
    }

    /// macOS can stop an idle web page after a long time; load it again instead of showing a blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        push()
        onLoaded?()
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "save":
            guard let raw = body["events"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let list = try? JSONDecoder().decode([ScheduleEvent].self, from: data) else { return }
            store.replace(list)
        case "added":
            if let date = body["date"] as? String { onAdded?(date) }
        default:
            break
        }
    }

    /// Portrait of the pet for the page header (head and shoulders, at full detail), as a data URI.
    static func portrait(from frame: Frame?) -> String {
        guard let f = frame else { return "" }
        let side: CGFloat = 84
        let crop = CGRect(x: max(0, f.head.x - side / 2), y: max(0, f.head.y - 4), width: side, height: side)
        guard let img = f.image.cropping(to: crop) else { return "" }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

/// `Pug --schedule-preview out.png`: render the schedule page with sample data (for the README).
enum SchedulePreview {
    static func run(_ out: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pug-preview-\(getpid()).json")
        let store = ScheduleStore(url: tmp)
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func day(_ d: Int) -> String { f.string(from: cal.date(byAdding: .day, value: d, to: Date())!) }
        store.replace([
            ScheduleEvent(id: "1", date: day(0), time: "09:00", title: "Team meeting", detail: "Bring the slides", notified: true),
            ScheduleEvent(id: "2", date: day(0), time: "12:30", title: "Lunch together", detail: "Usual place", notified: false),
            ScheduleEvent(id: "3", date: day(0), time: "15:00", title: "Hand in report", detail: "Chapter 3", notified: false),
            ScheduleEvent(id: "4", date: day(0), time: "20:00", title: "Call", detail: "", notified: false),
            ScheduleEvent(id: "5", date: day(2), time: "10:00", title: "Exam", detail: "Statistics", notified: false),
            ScheduleEvent(id: "6", date: day(5), end: day(8), time: "08:00", title: "Trip to Chiang Mai", detail: "Anniversary", notified: false, countdown: true),
            ScheduleEvent(id: "7", date: day(-20), time: "00:00", title: "Our anniversary", detail: "", notified: false, repeats: "month", ahead: 1440),
        ])
        let frames = AppController.petFrames()
        let w = ScheduleWindow(store: store, avatar: ScheduleWindow.portrait(from: frames?["stand.normal.0"]))
        var done = false
        var status: Int32 = 1
        w.onLoaded = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                w.web.takeSnapshot(with: nil) { image, _ in
                    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        status = 0
                    }
                    done = true
                }
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try? FileManager.default.removeItem(at: tmp)
        return status
    }
}
