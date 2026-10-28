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

    var due: Date? { ScheduleStore.parser.date(from: "\(date) \(time)") }
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
        if let data = try? Data(contentsOf: self.url),
           let list = try? JSONDecoder().decode([ScheduleEvent].self, from: data) {
            events = list
        }
    }

    func replace(_ list: [ScheduleEvent]) {
        events = list
        save()
    }

    func markNotified(_ id: String) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].notified = true
        save()
    }

    func count(on date: String) -> Int { events.filter { $0.date <= date && ($0.end ?? $0.date) >= date }.count }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(events) { try? data.write(to: url, options: .atomic) }
    }

    /// Events whose time has come and that have not been announced yet.
    func due(at now: Date) -> [ScheduleEvent] {
        events.filter { !$0.notified && ($0.due.map { $0 <= now } ?? false) }
            .sorted { $0.time < $1.time }
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
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = "Pug's Schedule"
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
            ScheduleEvent(id: "6", date: day(5), end: day(8), time: "08:00", title: "Trip to Chiang Mai", detail: "Anniversary", notified: false),
        ])
        let frames = AppController.outfitFrames(0)
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
