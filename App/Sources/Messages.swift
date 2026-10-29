import Foundation

/// Speech-bubble lines, editable by the user in ~/Library/Application Support/Pug/messages.json.
/// A broken or missing file never breaks the pet: it falls back to the bundled defaults.
final class Messages {
    let userURL: URL
    private let defaults: [String: [String]]
    private var cache: [String: [String]] = [:]
    private var loadedStamp: Date?

    /// The lines for the chosen language (Menu → Language).
    static func current() -> Messages {
        let name = L.thai ? "messages.th" : "messages"
        return Messages(bundled: Bundle.main.url(forResource: name, withExtension: "json"), userFile: name + ".json")
    }

    init(bundled: URL?, userFile: String = "messages.json") {
        var d: [String: [String]] = [:]
        if let u = bundled, let parsed = Messages.parse(u) { d = parsed }
        defaults = d
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pug", isDirectory: true)
        userURL = dir.appendingPathComponent(userFile)
        if !FileManager.default.fileExists(atPath: userURL.path), let b = bundled {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: b, to: userURL)
        }
    }

    init(fixed: [String: [String]]) {
        defaults = fixed
        userURL = URL(fileURLWithPath: "/dev/null")
    }

    func lines(_ key: String) -> [String] {
        reloadIfNeeded()
        if let l = cache[key], !l.isEmpty { return l }
        return defaults[key] ?? []
    }

    private func reloadIfNeeded() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: userURL.path))?[.modificationDate] as? Date
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp
        cache = Messages.parse(userURL) ?? [:]
    }

    static func parse(_ url: URL) -> [String: [String]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // TextEdit turns typed quotes into curly ones, which breaks the JSON; try again with straight ones
        let straight = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        guard let obj = ((try? JSONSerialization.jsonObject(with: data)) ?? (try? JSONSerialization.jsonObject(with: Data(straight.utf8))))
                as? [String: Any] else { return nil }
        var out: [String: [String]] = [:]
        for (k, v) in obj {
            if let list = v as? [String] {
                out[k] = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        }
        return out
    }
}
