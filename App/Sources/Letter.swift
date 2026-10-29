import AppKit
import WebKit

/// The anniversary letter shown on first launch (and again from the menu). Its words live in
/// letter.json; the last page has a gift that, when opened, brings the pet onto the screen.
final class LetterWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Letter: Decodable {
        var title = ""
        var pages: [String] = []
        var button = ""
        var signature = ""
        var after: [String] = []
    }

    static func load() -> Letter {
        guard let url = Bundle.main.url(forResource: "letter", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let l = try? JSONDecoder().decode(Letter.self, from: data) else { return Letter() }
        return l
    }

    let window: NSWindow
    let web: WKWebView
    private let json: String
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 560, height: 600), configuration: config)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let raw = Bundle.main.url(forResource: "letter", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        json = raw.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        super.init()
        config.userContentController.add(WeakLetterHandler(self), name: "letter")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = "A letter for you"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.onClose?()
        }
        if let page = Bundle.main.url(forResource: "letter", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("LETTER.load(\(json))", completionHandler: nil)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["op"] as? String == "open" else { return }
        window.orderOut(nil)
        onOpen?()
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakLetterHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// `Pug --letter-preview out.png [page]`: snapshot of the letter (for the README).
enum LetterPreview {
    static func run(_ out: String, page: Int) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let w = LetterWindow()
        var done = false, status: Int32 = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            w.web.evaluateJavaScript("for (let i = 0; i < \(page); i++) document.getElementById('next').click()") { _, _ in
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
        }
        let deadline = Date().addingTimeInterval(15)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return status
    }
}

/// "How to play": short lessons, one per page, on what she can do with the pet (guide.html).
final class GuideWindow {
    let window: NSWindow
    let web: WKWebView

    init() {
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 760, height: 660))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        web.setValue(false, forKey: "drawsBackground")
        window.title = "How to play with Pug"
        window.contentView = web
        window.minSize = CGSize(width: 420, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        if let page = Bundle.main.url(forResource: "guide", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// `Pug --guide-preview out.png [lesson]`: snapshot of one lesson of the how-to-play page.
enum GuidePreview {
    static func run(_ out: String, lesson: Int) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let w = GuideWindow()
        var done = false, status: Int32 = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            w.web.evaluateJavaScript("GUIDE.go(\(lesson))", completionHandler: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            w.web.takeSnapshot(with: nil) { image, _ in
                if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    status = 0
                }
                done = true
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return status
    }
}
