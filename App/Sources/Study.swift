import AppKit
import Security
import WebKit

/// "SAT Math": practice by lesson with a mistake log (study.html), and a tutor she can ask about
/// a screenshot of a question. Questions come from study.json (shipped with the app; a newer copy
/// on GitHub replaces it); her progress is kept in Application Support/Pug/study-progress.json.
final class StudyWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let web: WKWebView
    private var loaded = false
    private var pendingImage: String?  // a picture to start a question with once the page is ready
    var onCheer: ((String) -> Void)?

    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pug", isDirectory: true)
    static let progressURL = dir.appendingPathComponent("study-progress.json")
    static let bankCache = dir.appendingPathComponent("study.json")

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.LANG = '\(Settings.language)'",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 720), configuration: config)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(WeakStudyHandler(self), name: "study")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = L.t("SAT Math")
        window.contentView = web
        window.minSize = CGSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        if let page = Bundle.main.url(forResource: "study", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Open the tutor with this picture (from the clipboard or dropped on him) ready to ask about.
    func ask(withImage png: Data) {
        let b64 = png.base64EncodedString()
        if loaded { web.evaluateJavaScript("STUDY.askWith('\(b64)')", completionHandler: nil) } else { pendingImage = b64 }
        show()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let bank = (try? Data(contentsOf: StudyWindow.bankCache)) ?? Bundle.main.url(forResource: "study", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let progress = (try? Data(contentsOf: StudyWindow.progressURL)) ?? Data("{}".utf8)
        let js = { (d: Data?) in d.flatMap { String(data: $0, encoding: .utf8) } ?? "null" }
        web.evaluateJavaScript("STUDY.load(\(js(bank)), \(js(progress)), \(Tutor.hasKey))", completionHandler: nil)
        if let b = pendingImage {
            pendingImage = nil
            web.evaluateJavaScript("STUDY.askWith('\(b)')", completionHandler: nil)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "save":
            // progress, written whole each time (small)
            guard let p = body["progress"], let data = try? JSONSerialization.data(withJSONObject: p) else { return }
            try? FileManager.default.createDirectory(at: StudyWindow.dir, withIntermediateDirectories: true)
            try? data.write(to: StudyWindow.progressURL, options: .atomic)
        case "cheer":
            onCheer?(body["kind"] as? String ?? "")
        case "key":
            Tutor.saveKey((body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            web.evaluateJavaScript("STUDY.keySaved(\(Tutor.hasKey))", completionHandler: nil)
        case "ask":
            guard let messages = body["messages"] as? [[String: Any]], let id = body["id"] as? Int else { return }
            Tutor.ask(messages) { [weak self] result in
                guard let self else { return }
                let json: String
                switch result {
                case .success(let content):
                    json = String(data: (try? JSONSerialization.data(withJSONObject: ["ok": true, "content": content])) ?? Data(), encoding: .utf8) ?? "{}"
                case .failure(let e):
                    json = String(data: (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": e.message])) ?? Data(), encoding: .utf8) ?? "{}"
                }
                self.web.evaluateJavaScript("STUDY.answer(\(id), \(json))", completionHandler: nil)
            }
        default:
            break
        }
    }

    /// The newest question bank from GitHub, kept for next time (and for offline use).
    static func refreshBank() {
        let req = URLRequest(url: URL(string: Updater.base + "App/Resources/study.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["questions"] is [Any] else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: bankCache, options: .atomic)
        }.resume()
    }

    /// Today's practice done? (for his evening nudge)
    static var practisedToday: Bool {
        guard let data = try? Data(contentsOf: progressURL),
              let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = p["daily"] as? [String: Any], let day = daily["date"] as? String else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return day == f.string(from: Date()) && (daily["done"] as? Int ?? 0) >= 5
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakStudyHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// The SAT Math tutor: Claude reads her screenshot and explains what to do and the answer.
/// Raw HTTP to the Messages API (there is no official Swift SDK). The API key is kept in the
/// Keychain on her Mac, never in the app or the repo.
enum Tutor {
    struct Failure: Error { let message: String }

    static let model = "claude-opus-5-5"
    private static let service = "com.pug.desktoppet.tutor"

    static let system = """
    You are a patient SAT Math tutor for a Thai high-school student preparing for the Digital SAT \
    (Bluebook, Desmos calculator built in). She sends screenshots of questions, often with her own \
    handwriting on them, and follow-up questions.

    For a question, reply in clear, simple English (she reads English well but it is her second \
    language), in this order:
    1. What it asks: one sentence.
    2. Key idea: the concept or formula, and any wording trap ("at least", "given that", \
    "in terms of", "equivalent", "best interpretation").
    3. Steps: short numbered steps with the working.
    4. Answer: the final answer on its own line, starting with "Answer:". For a multiple-choice \
    question give the letter and the value. For a typed answer give the exact value (a fraction \
    such as 7/2 is fine); never round a value that is exact.
    5. Desmos: only when graphing or a table in Desmos is genuinely faster, one line on how.

    If her handwriting shows a different answer, say kindly where it went wrong. If the picture is \
    unreadable or not a math question, say so and ask for a clearer screenshot. Keep it short: no \
    preamble, no restating the whole question. Plain text with numbered lists; write math inline \
    like x^2, √(x+1), 3/4.
    """

    // MARK: key (Keychain)

    static var hasKey: Bool { key != nil }

    static var key: String? {
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Store the key (an empty string removes it).
    static func saveKey(_ k: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !k.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(k.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: asking

    /// One turn: the whole conversation so far (her messages, and his earlier replies exactly as
    /// the API returned them, thinking blocks included), and back comes the reply's content blocks.
    static func ask(_ messages: [[String: Any]], done: @escaping (Result<[[String: Any]], Failure>) -> Void) {
        guard let key else { return done(.failure(Failure(message: L.t("Add an API key first.")))) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // if a safety check declines, the API retries on a suitable model instead of stopping
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],  // getting the maths right matters more than speed here
            "fallbacks": "default",
            "messages": messages,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<[[String: Any]], Failure>
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if err != nil {
                result = .failure(Failure(message: L.t("Couldn't reach Claude. Check that you're online, then try again.")))
            } else if status == 401 {
                result = .failure(Failure(message: L.t("The API key didn't work. Check it, or ask for a new one.")))
            } else if status == 429 || status == 529 || status >= 500 {
                result = .failure(Failure(message: L.t("Claude is busy right now. Try again in a minute.")))
            } else if status != 200 {
                let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
                result = .failure(Failure(message: msg))
            } else if obj?["stop_reason"] as? String == "refusal" {
                result = .failure(Failure(message: L.t("Claude couldn't answer that one. Try another screenshot.")))
            } else if let content = obj?["content"] as? [[String: Any]] {
                result = .success(content)
            } else {
                result = .failure(Failure(message: L.t("Something went wrong. Try again.")))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}
