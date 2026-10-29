import Foundation

/// Things he keeps sending her after the gift, from love.json on GitHub (a copy ships with the
/// app for when she is offline): notes he says out loud once each, and a letter for each monthly
/// anniversary. "Miss you" rings his phone through ntfy.sh; its topic is kept on her Mac only,
/// never in the public repo.
final class Love {
    struct Content: Decodable {
        struct Note: Decodable {
            let id: String
            let show_from: String?  // yyyy-MM-dd; not before this day
            let text: String
        }
        var since: String?           // the day they got together, yyyy-MM-dd
        var notes: [Note]?
        var letters: [String: LetterWindow.Letter]?  // by month count, "8", "9", ...
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

    /// How many months together today is, when today is a monthly anniversary (the 29th, or a
    /// short month's last day); nil on other days.
    func anniversaryMonths(now: Date = Date()) -> Int? {
        guard let s = content.since, let start = Love.day.date(from: s) else { return nil }
        let cal = Love.day.calendar!
        let months = cal.dateComponents([.month], from: start, to: now).month ?? 0
        guard months >= 1, let d = cal.date(byAdding: .month, value: months, to: start) else { return nil }
        return Love.day.string(from: d) == Love.today(now) ? months : nil
    }

    /// The letter for the newest anniversary that has one, up to today.
    func latestLetter(now: Date = Date()) -> (months: Int, letter: LetterWindow.Letter)? {
        guard let s = content.since, let start = Love.day.date(from: s) else { return nil }
        var months = Love.day.calendar!.dateComponents([.month], from: start, to: now).month ?? 0
        while months > 0 {
            if let l = content.letters?[String(months)] { return (months, l) }
            months -= 1
        }
        return nil
    }

    /// Ring his phone: a push through ntfy.sh to the topic she was given.
    static func sendMissYou(topic: String, _ done: @escaping (Bool) -> Void) {
        guard !topic.isEmpty, let url = URL(string: "https://ntfy.sh/" + topic) else { return done(false) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Pug", forHTTPHeaderField: "Title")
        req.httpBody = "She misses you (from Pug)".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }
}
