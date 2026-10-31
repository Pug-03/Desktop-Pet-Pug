import AppKit
import UniformTypeIdentifiers

/// Things she leaves with him: screenshots, pictures and files dropped on him (or pasted from
/// the clipboard) are copied into ~/Library/Application Support/Pug/Stash, and come back out
/// of the "Stash" window by dragging, double-clicking or the right-click menu.
final class StashStore {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pug/Stash", isDirectory: true)
    var onChange: (() -> Void)?

    /// Newest first.
    var items: [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func made(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return urls.sorted { made($0) > made($1) }
    }

    /// Pasteboard types a drop can bring: files, promised files (the screenshot thumbnail), images.
    static let dropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canTake(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self, NSImage.self],
                         options: [.urlReadingFileURLsOnly: true])
    }

    /// Copy whatever is on the pasteboard into the stash; `done` gets how many things came in.
    func take(_ pb: NSPasteboard, done: @escaping (Int) -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let n = urls.filter { copyIn($0) }.count
            finish(n, done)
        } else if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            // the screenshot thumbnail and some apps hand over files that are written on request
            let group = DispatchGroup()
            var n = 0
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, err in
                    if err == nil { n += 1; self.touch(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { self.finish(n, done) }
        } else if let img = NSImage(pasteboard: pb), let png = Self.png(img) {
            let url = unique("Picture \(Self.stamp()).png")
            finish((try? png.write(to: url)) != nil ? 1 : 0, done)
        } else {
            done(0)
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)  // to the Bin, so a slip can be undone
        onChange?()
    }

    private func finish(_ n: Int, _ done: (Int) -> Void) {
        if n > 0 { onChange?() }
        done(n)
    }

    private func copyIn(_ src: URL) -> Bool {
        let dst = unique(src.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return false }
        touch(dst)
        return true
    }

    /// The order is by when it was left here, not when the original was made.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.creationDate: Date(), .modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func unique(_ name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// The stash window: a pixel-style shelf of what she left with him.
final class StashWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let shelf: StashShelf

    init(store: StashStore) {
        shelf = StashShelf(store: store)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = L.t("Stash")
        let scroll = NSScrollView()
        scroll.documentView = shelf
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = StashShelf.bg
        window.contentView = scroll
        window.minSize = CGSize(width: 360, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        shelf.frame = CGRect(origin: .zero, size: scroll.contentSize)
        shelf.autoresizingMask = [.width]
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(shelf)
    }

    func reload() { shelf.reload() }
}

/// The tiles, drawn like the schedule: ink frames with notched corners on light blue checks.
final class StashShelf: NSView, NSDraggingSource {
    static let bg = NSColor(calibratedRed: 0.863, green: 0.925, blue: 0.980, alpha: 1)
    private static let ink = NSColor(calibratedRed: 0.122, green: 0.176, blue: 0.251, alpha: 1)
    private static let paper = NSColor(calibratedRed: 0.973, green: 0.988, blue: 1, alpha: 1)
    private static let muted = NSColor(calibratedRed: 0.36, green: 0.435, blue: 0.518, alpha: 1)
    private static let accent = NSColor(calibratedRed: 0.31, green: 0.64, blue: 0.89, alpha: 1)
    private static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let f = NSFont(name: "Silom", size: size) ?? .systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
    }

    private let store: StashStore
    private var items: [URL] = []
    private var thumbs: [URL: NSImage] = [:]
    private var selected: URL?
    private var downAt: (point: CGPoint, item: URL)?
    private var dropping = false

    private let tile = CGSize(width: 132, height: 150), gap: CGFloat = 18, top: CGFloat = 92, side: CGFloat = 22

    init(store: StashStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes(StashStore.dropTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        items = store.items
        thumbs = thumbs.filter { items.contains($0.key) }
        if let s = selected, !items.contains(s) { selected = nil }
        relayout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private var columns: Int { max(1, Int((bounds.width - side * 2 + gap) / (tile.width + gap))) }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: side + CGFloat(i % columns) * (tile.width + gap), y: top + CGFloat(i / columns) * (tile.height + gap),
               width: tile.width, height: tile.height)
    }

    private func relayout() {
        let rows = (items.count + columns - 1) / columns
        let h = max(top + CGFloat(rows) * (tile.height + gap) + gap, enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - h) > 0.5 { super.setFrameSize(CGSize(width: frame.width, height: h)) }
    }

    private func item(at p: CGPoint) -> URL? {
        items.indices.first { rect($0).contains(p) }.map { items[$0] }
    }

    private func thumb(_ url: URL) -> NSImage {
        if let t = thumbs[url] { return t }
        let isImage = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
        let t = (isImage ? NSImage(contentsOf: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
        thumbs[url] = t
        return t
    }

    // MARK: drawing

    private func pixelBox(_ r: CGRect, fill: NSColor, line: CGFloat = 3, shadow: Bool = true) {
        if shadow {
            NSColor(calibratedRed: 0.122, green: 0.176, blue: 0.251, alpha: 0.2).setFill()
            r.offsetBy(dx: line * 2, dy: line * 2).insetBy(dx: line, dy: line).fill()
        }
        Self.ink.setFill()
        r.insetBy(dx: line, dy: 0).fill()
        r.insetBy(dx: 0, dy: line).fill()
        fill.setFill()
        r.insetBy(dx: line, dy: line).fill()
    }

    override func draw(_ dirty: NSRect) {
        Self.bg.setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        let s: CGFloat = 8
        for y in stride(from: dirty.minY - dirty.minY.truncatingRemainder(dividingBy: s), to: dirty.maxY, by: s) {
            for x in stride(from: 0, to: bounds.width, by: s * 2) {
                CGRect(x: x + (Int(y / s) % 2 == 0 ? 0 : s), y: y, width: s, height: s).fill()
            }
        }

        let head = CGRect(x: side - 4, y: 16, width: bounds.width - side * 2 + 8, height: 58)
        pixelBox(head, fill: dropping ? Self.accent.blended(withFraction: 0.75, of: .white)! : Self.paper, line: 4)
        let title = L.t("Things you left with Pug") + (items.isEmpty ? "" : "  (\(items.count))")
        (title as NSString).draw(at: CGPoint(x: head.minX + 16, y: head.minY + 9),
                                 withAttributes: [.font: Self.font(18, bold: true), .foregroundColor: Self.ink])
        let hint = L.t("Drop pictures or files on Pug or here. Drag them out to use them; double-click to open.")
        (hint as NSString).draw(in: CGRect(x: head.minX + 16, y: head.minY + 33, width: head.width - 32, height: 20),
                                withAttributes: [.font: Self.font(12), .foregroundColor: Self.muted])

        if items.isEmpty {
            let msg = L.t("Nothing here yet. Take a screenshot and drag it onto Pug.") as NSString
            let a: [NSAttributedString.Key: Any] = [.font: Self.font(15), .foregroundColor: Self.muted]
            let w = msg.size(withAttributes: a).width
            msg.draw(at: CGPoint(x: (bounds.width - w) / 2, y: top + 60), withAttributes: a)
            return
        }

        let label: [NSAttributedString.Key: Any] = [.font: Self.font(12), .foregroundColor: Self.ink, .paragraphStyle: {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle; p.alignment = .center; return p }()]
        for (i, url) in items.enumerated() {
            let r = rect(i)
            guard r.intersects(dirty) else { continue }
            pixelBox(r, fill: url == selected ? Self.accent.blended(withFraction: 0.7, of: .white)! : Self.paper)
            let pic = CGRect(x: r.minX + 12, y: r.minY + 12, width: r.width - 24, height: r.height - 48)
            let img = thumb(url)
            let k = min(pic.width / max(img.size.width, 1), pic.height / max(img.size.height, 1), 1.0 * (img.size.width < 64 ? 2 : 1))
            let sz = CGSize(width: img.size.width * k, height: img.size.height * k)
            img.draw(in: CGRect(x: pic.midX - sz.width / 2, y: pic.midY - sz.height / 2, width: sz.width, height: sz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            (url.lastPathComponent as NSString).draw(in: CGRect(x: r.minX + 8, y: r.maxY - 30, width: r.width - 16, height: 18), withAttributes: label)
        }
    }

    // MARK: mouse: select, open, drag out, right-click

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        selected = item(at: p)
        downAt = selected.map { (p, $0) }
        needsDisplay = true
        if event.clickCount == 2, let s = selected { NSWorkspace.shared.open(s) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = downAt, hypot(p.x - d.point.x, p.y - d.point.y) > 4, let i = items.firstIndex(of: d.item) else { return }
        downAt = nil
        let drag = NSDraggingItem(pasteboardWriter: d.item as NSURL)
        drag.setDraggingFrame(rect(i).insetBy(dx: 12, dy: 12), contents: thumb(d.item))
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let url = item(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selected = url
        needsDisplay = true
        let m = NSMenu()
        for (title, action) in [("Open", #selector(openItem)), ("Copy", #selector(copyItem)),
                                ("Show in Finder", #selector(revealItem)), ("Move to Bin", #selector(deleteItem))] {
            let i = NSMenuItem(title: L.t(title), action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = url
            m.addItem(i)
        }
        return m
    }

    @objc private func openItem(_ s: NSMenuItem) { (s.representedObject as? URL).map { _ = NSWorkspace.shared.open($0) } }
    @objc private func revealItem(_ s: NSMenuItem) { (s.representedObject as? URL).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
    @objc private func deleteItem(_ s: NSMenuItem) { (s.representedObject as? URL).map { store.remove($0) } }

    /// A picture goes on the clipboard as a picture (to paste into a chat); anything else as a file.
    @objc private func copyItem(_ s: NSMenuItem) { (s.representedObject as? URL).map(copy) }
    private func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false, let img = NSImage(contentsOf: url) {
            pb.writeObjects([img, url as NSURL])
        } else {
            pb.writeObjects([url as NSURL])
        }
    }

    // Cmd-C copies the selected one, Cmd-V leaves the clipboard here, Delete moves it to the Bin
    @objc func copy(_ sender: Any?) { selected.map(copy) }
    @objc func paste(_ sender: Any?) { store.take(.general) { _ in } }
    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), let s = selected { store.remove(s) } else { super.keyDown(with: event) }
    }

    // MARK: drops into the window

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? StashShelf !== self, StashStore.canTake(sender.draggingPasteboard) else { return [] }
        dropping = true
        needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropping = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        store.take(sender.draggingPasteboard) { _ in }
        return true
    }
}
