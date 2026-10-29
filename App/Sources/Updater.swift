import AppKit

/// Updates Pug from GitHub: latest.json says which build is out, Pug.zip holds it. The new app
/// replaces this one in place and is opened again, so plans and settings carry over.
enum Updater {
    static let base = "https://raw.githubusercontent.com/Pug-03/Desktop-Pet-Pug/main/"

    struct Latest: Decodable {
        let version: String
        let build: Int
    }

    enum Failure: LocalizedError {
        case download, unpack, notNewer, notInApplications, replace(String)
        var errorDescription: String? {
            switch self {
            case .download: return "The download didn't finish. Check that you're online, then try again."
            case .unpack: return "The downloaded file was damaged. Try again in a few minutes."
            case .notNewer: return "GitHub is still sending the old version. Try again in a few minutes."
            case .notInApplications: return "Pug is running from Downloads. Drag Pug into your Applications folder, open it from there, then update."
            case .replace(let why): return "Pug couldn't replace itself (\(why))."
            }
        }
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// The newest build on GitHub (nil when it can't be reached).
    static func fetchLatest(_ done: @escaping (Latest?) -> Void) {
        let req = URLRequest(url: URL(string: base + "latest.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let latest = ok ? data.flatMap { try? JSONDecoder().decode(Latest.self, from: $0) } : nil
            DispatchQueue.main.async { done(latest) }
        }.resume()
    }

    /// Download and swap in the new app, then reopen it. `failed` gets a message to show her.
    static func install(_ latest: Latest, failed: @escaping (String) -> Void) {
        let url = URL(string: base + "Pug.zip?build=\(latest.build)")!  // a new URL per build, past any cache
        URLSession.shared.downloadTask(with: url) { tmp, resp, _ in
            // the downloaded file is deleted when this handler returns, so unpack it here
            let result = Result { () throws -> URL in
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
                return try replace(with: tmp)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let app): relaunch(app)
                case .failure(let e): failed((e as? Failure ?? .replace(e.localizedDescription)).errorDescription ?? "")
                }
            }
        }.resume()
    }

    private static func replace(with zip: URL) throws -> URL {
        let fm = FileManager.default
        let here = Bundle.main.bundleURL
        if here.path.contains("/AppTranslocation/") { throw Failure.notInApplications }
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: here, create: true)
        defer { try? fm.removeItem(at: work) }
        guard run("/usr/bin/ditto", "-x", "-k", zip.path, work.path) else { throw Failure.unpack }
        let app = work.appendingPathComponent("Pug.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let b = (info?["CFBundleVersion"] as? String).flatMap(Int.init) else { throw Failure.unpack }
        guard b > build else { throw Failure.notNewer }
        _ = run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path)
        do {
            return try fm.replaceItemAt(here, withItemAt: app) ?? here
        } catch {
            throw Failure.replace(error.localizedDescription)
        }
    }

    /// Quit, and open the new copy a moment later.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: String...) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
