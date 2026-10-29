import Foundation

/// Things he keeps sending her after the gift, from love.json on GitHub (a copy ships with the
/// app for when she is offline): notes he says out loud once each.
final class Love {
    struct Content: Decodable {
        struct Note: Decodable {
            let id: String
            let show_from: String?  // yyyy-MM-dd; not before this day
            let text: String
        }
        var notes: [Note]?
    }

    private(set) var content = Content()
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pug/love.json")
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        for url in [cacheURL, Bundle.main.url(forResource: "love", withExtension: "json")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Content.self, from: data) {
                content = c
                return
            }
        }
    }

    /// Get the newest love.json; keeps the last good copy when GitHub can't be reached.
    func refresh(_ done: @escaping () -> Void) {
        let req = URLRequest(url: URL(string: Updater.base + "love.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self, (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                      let c = try? JSONDecoder().decode(Content.self, from: data) else { return done() }
                self.content = c
                try? data.write(to: self.cacheURL, options: .atomic)
                done()
            }
        }.resume()
    }

    static func today(_ now: Date = Date()) -> String { day.string(from: now) }

    /// Notes that are due and that he hasn't said yet, oldest first.
    func unseenNotes(seen: Set<String>, now: Date = Date()) -> [Content.Note] {
        let t = Love.today(now)
        return (content.notes ?? []).filter { !seen.contains($0.id) && ($0.show_from ?? "") <= t }
    }

    /// The newest note that is already due (for "read it again").
    func latestNote(now: Date = Date()) -> Content.Note? {
        let t = Love.today(now)
        return (content.notes ?? []).last { ($0.show_from ?? "") <= t }
    }


}
