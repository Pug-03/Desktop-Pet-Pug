import AppKit

/// User preferences, persisted in UserDefaults.
struct Settings {
    private static let d = UserDefaults.standard

    static var size: Int {  // 0 small, 1 medium, 2 large
        get { d.object(forKey: "size") as? Int ?? 1 }
        set { d.set(newValue, forKey: "size") }
    }
    static var sleepMinutes: Double {
        get { d.object(forKey: "sleepMinutes") as? Double ?? 3 }
        set { d.set(newValue, forKey: "sleepMinutes") }
    }
    static var walking: Bool {
        get { d.object(forKey: "walking") as? Bool ?? true }
        set { d.set(newValue, forKey: "walking") }
    }
    static var outfit: Int {  // 0 = black suit, 1-16 = outfits sheet
        get { d.object(forKey: "outfit") as? Int ?? 0 }
        set { d.set(newValue, forKey: "outfit") }
    }
    static var firstRunDone: Bool {
        get { d.bool(forKey: "firstRunDone") }
        set { d.set(newValue, forKey: "firstRunDone") }
    }

    static func scale(_ size: Int) -> CGFloat { [0.4, 0.5, 0.65][max(0, min(2, size))] }
}

/// Starts the app at login through a per-user LaunchAgent.
enum LoginItem {
    static let label = "com.pug.desktoppet"
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [exe], "RunAtLoad": true,
                                        "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PetView: NSView {
    weak var controller: AppController?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller, let ctx = NSGraphicsContext.current?.cgContext, let w = window else { return }
        ctx.clear(bounds)
        let screen = c.bounds(near: c.engine.feet)
        c.renderer.draw(c.engine, in: ctx, origin: w.frame.origin, screen: screen, pixel: 1 / w.backingScaleFactor)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.engine.pointerDown(NSEvent.mouseLocation)
        controller?.kick()
    }
    override func mouseDragged(with event: NSEvent) { controller?.engine.pointerMoved(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { controller?.engine.pointerUp(NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        NSMenu.popUpContextMenu(c.buildMenu(), with: event, for: self)
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var engine: PetEngine!
    private(set) var renderer: Renderer!
    private var panel: PetPanel!
    private var view: PetView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var timerFPS = 0.0
    private var lastTick = CACurrentMediaTime()
    private var messages: Messages!
    private var hidden = false
    private var winSize = CGSize(width: 300, height: 360)
    private let schedule = ScheduleStore()
    private var scheduleWindow: ScheduleWindow?
    private var reminderTimer: Timer?
    private var recentAdds: [Date] = []

    // MARK: - setup

    /// Sprite atlas for an outfit; only the one being worn is kept in memory.
    static func outfitFrames(_ n: Int) -> [String: Frame]? {
        let res = Bundle.main.resourceURL!.appendingPathComponent("sprites")
        let name = n == 0 ? "pet" : "pet_o\(n)"
        return Atlas.load(png: res.appendingPathComponent("\(name).png"), json: res.appendingPathComponent("\(name).json"))
    }

    private lazy var outfitNames: [String] = {
        let url = Bundle.main.resourceURL!.appendingPathComponent("sprites/outfits.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String] ?? ["สูทดำ"]
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        let res = Bundle.main.resourceURL!
        messages = Messages(bundled: res.appendingPathComponent("messages.json"))
        guard let fx = Atlas.load(png: res.appendingPathComponent("sprites/effects.png"),
                                  json: res.appendingPathComponent("sprites/effects.json")),
              let frames = AppController.outfitFrames(Settings.outfit) ?? AppController.outfitFrames(0)
        else {
            NSLog("Pug: sprites missing from bundle")
            NSApp.terminate(nil)
            return
        }
        renderer = Renderer(effects: fx)

        let main = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        engine = PetEngine(frames: frames, scale: Settings.scale(Settings.size),
                           start: CGPoint(x: main.midX, y: main.minY),
                           seed: UInt64(Date().timeIntervalSince1970 * 1000),
                           screenBounds: { [weak self] p in self?.bounds(near: p) ?? main },
                           messages: { [weak self] k in self?.messages.lines(k) ?? [] })
        applySettings()

        panel = PetPanel(contentRect: CGRect(origin: .zero, size: winSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar  // above the Dock, which slides up under the pet when hidden
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        view = PetView(frame: CGRect(origin: .zero, size: winSize))
        view.controller = self
        view.wantsLayer = true
        panel.contentView = view
        resizeWindow()
        panel.orderFrontRegardless()

        setupStatusItem()
        setupEditMenu()
        startReminders()

        if !Settings.firstRunDone {
            Settings.firstRunDone = true
            LoginItem.set(true)
        } else if LoginItem.enabled {
            LoginItem.set(true)  // refresh the path in case the app was moved
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        engine.dropIn(atX: main.midX + CGFloat.random(in: -200...200))
        kick()
    }

    private func applySettings() {
        engine.sleepAfter = Settings.sleepMinutes * 60
        engine.walkingEnabled = Settings.walking
    }

    private func resizeWindow() {
        let maxDim = engine.frames.values.reduce(CGFloat(0)) { max($0, CGFloat(max($1.width, $1.height))) } * engine.scale
        winSize = CGSize(width: ceil(maxDim * 2 + 60), height: ceil(maxDim * 2 + 180))
        panel.setContentSize(winSize)
        view.frame = CGRect(origin: .zero, size: winSize)
        layoutWindow()
    }

    func bounds(near p: CGPoint) -> CGRect {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) { return walkArea(s, x: p.x) }
        // nearest screen horizontally (the pet walks along the bottom)
        let best = screens.min { a, b in
            abs(a.frame.midX - p.x) + abs(a.frame.midY - p.y) < abs(b.frame.midX - p.x) + abs(b.frame.midY - p.y)
        }
        return best.map { walkArea($0, x: p.x) } ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Stand on top of the Dock when it is showing and `x` is above it; past either end of
    /// the Dock, or when it is hidden (auto-hide, or a full-screen app in front), stand on the
    /// real bottom edge of the screen instead.
    func walkArea(_ s: NSScreen, x: CGFloat) -> CGRect {
        let v = s.visibleFrame
        let half = min(dockWidth(), s.frame.width) / 2
        let dockShown = v.minY - s.frame.minY > 10 && !fullScreenFrames().contains(s.frame)
            && abs(x - s.frame.midX) < half
        let floor = dockShown ? v.minY : s.frame.minY
        return CGRect(x: v.minX, y: floor, width: v.width, height: v.maxY - floor)
    }

    private var dockCache: (time: CFTimeInterval, width: CGFloat) = (-10, 0)

    /// The Dock window covers the whole screen, so its bar width is estimated from the Dock's
    /// own settings: Finder + kept apps + recent/running apps + folders + Trash, plus separators.
    private func dockWidth() -> CGFloat {
        let now = CACurrentMediaTime()
        if now - dockCache.time < 2 { return dockCache.width }
        let d = UserDefaults(suiteName: "com.apple.dock")
        func ids(_ k: String) -> [String] {
            (d?.array(forKey: k) as? [[String: Any]] ?? []).compactMap {
                ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
            }
        }
        let kept = ids("persistent-apps")
        let showRecents = d?.object(forKey: "show-recents") as? Bool ?? true
        var middle = Set(showRecents ? ids("recent-apps") : [])
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            if let id = a.bundleIdentifier, id != "com.apple.finder", !kept.contains(id) { middle.insert(id) }
        }
        let others = d?.array(forKey: "persistent-others")?.count ?? 0
        let tiles = CGFloat(1 + kept.count + middle.count + others + 1)
        let separators: CGFloat = middle.isEmpty ? 1 : 2
        let tile = CGFloat(d?.object(forKey: "tilesize") as? Double ?? 48)
        let width = (tiles + 0.5 * separators) * tile * 1.06 + 8
        dockCache = (now, width)
        return width
    }

    private var fullScreenCache: [CGRect]?

    /// Screen frames currently covered by a full-screen app window. Re-read only after a Space
    /// switch settles (see `spaceChanged`), so a half-finished swipe never moves the floor.
    private func fullScreenFrames() -> [CGRect] {
        if let f = fullScreenCache { return f }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var frames: [CGRect] = []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d) else { continue }
            let flipped = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            // full-screen windows on notched Macs stop below the notch, so only the width
            // and the bottom edge must match (a zoomed window stops above the Dock instead)
            if let s = NSScreen.screens.first(where: {
                abs(flipped.minX - $0.frame.minX) < 1 && abs(flipped.width - $0.frame.width) < 1
                    && abs(flipped.minY - $0.frame.minY) < 1 && flipped.height > $0.frame.height * 0.8
            }) { frames.append(s.frame) }
        }
        fullScreenCache = frames
        return frames
    }

    // MARK: - loop

    /// Restart the timer at the rate the current state wants.
    func kick() {
        let fps = engine.preferredFPS
        guard fps != timerFPS else { return }
        timerFPS = fps
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = 0.1 / fps
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard !hidden else { return }
        if engine.pressed && NSEvent.pressedMouseButtons & 1 == 0 {
            engine.pointerUp(NSEvent.mouseLocation)  // mouse released outside the window
        }
        engine.tick(dt)
        layoutWindow()
        let mouse = NSEvent.mouseLocation
        let over = engine.pressed || engine.state == .held || engine.hitTest(mouse)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        view.needsDisplay = true
        kick()
    }

    private func layoutWindow() {
        let c = engine.bodyCenter
        let origin = CGPoint(x: (c.x - winSize.width / 2).rounded(), y: (c.y - winSize.height / 2 + 60).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    @objc private func screensChanged() {
        fullScreenCache = nil
        engine.noteInteraction()
    }

    /// After a Space switch the pet is simply already standing on the new floor, no easing.
    @objc private func spaceChanged() {
        fullScreenCache = nil
        engine.settleOnFloor()
        // the window list can lag the notification a little
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fullScreenCache = nil
                self?.engine.settleOnFloor()
                self?.view.needsDisplay = true
            }
        }
        layoutWindow()
        view.needsDisplay = true
    }

    @objc private func didWake() {
        lastTick = CACurrentMediaTime()
        engine.noteInteraction()
    }

    // MARK: - menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let f = engine.frames["stand.normal.0"],
           let head = f.image.cropping(to: CGRect(x: f.head.x - 30, y: f.head.y, width: 60, height: 60)) {
            let img = NSImage(cgImage: head, size: NSSize(width: 18, height: 18))
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🐶"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, tag: Int = 0, on: Bool = false, to menu: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.state = on ? .on : .off
            (menu ?? m).addItem(i)
        }
        add(hidden ? "แสดงตัว" : "ซ่อนตัว", #selector(toggleHidden))
        add("เรียกมาหา", #selector(summon))
        add("พูดอะไรหน่อย", #selector(talk))
        add("ตาราง / แจ้งเตือน…", #selector(openSchedule))
        if engine.state == .sleeping { add("ปลุก", #selector(wake)) } else { add("ให้นอนเลย", #selector(sleepNow)) }
        m.addItem(.separator())

        let outfits = NSMenu()
        for (i, n) in outfitNames.enumerated() {
            add(n, #selector(setOutfit(_:)), tag: i, on: Settings.outfit == i, to: outfits)
        }
        outfits.addItem(.separator())
        add("สุ่มชุด", #selector(randomOutfit), to: outfits)
        let oi = NSMenuItem(title: "เปลี่ยนชุด", action: nil, keyEquivalent: "")
        oi.submenu = outfits
        m.addItem(oi)

        let size = NSMenu()
        for (i, n) in ["เล็ก", "กลาง", "ใหญ่"].enumerated() {
            add(n, #selector(setSize(_:)), tag: i, on: Settings.size == i, to: size)
        }
        let zi = NSMenuItem(title: "ขนาด", action: nil, keyEquivalent: "")
        zi.submenu = size
        m.addItem(zi)

        let sleep = NSMenu()
        for minutes in [1, 3, 5, 10, 30] {
            add("\(minutes) นาที", #selector(setSleep(_:)), tag: minutes, on: Int(Settings.sleepMinutes) == minutes, to: sleep)
        }
        let li = NSMenuItem(title: "ง่วงนอนเมื่อไม่มีใครเล่นด้วย", action: nil, keyEquivalent: "")
        li.submenu = sleep
        m.addItem(li)
        add("เดินเล่นไปมา", #selector(toggleWalking), on: Settings.walking)
        m.addItem(.separator())
        add("แก้ไขข้อความ…", #selector(editMessages))
        add("เปิดเองตอนเปิดเครื่อง", #selector(toggleLogin), on: LoginItem.enabled)
        m.addItem(.separator())
        add("ออก", #selector(quit))
        return m
    }

    @objc private func toggleHidden() {
        hidden.toggle()
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless(); engine.dropIn(atX: NSEvent.mouseLocation.x) }
        kick()
    }

    @objc private func summon() {
        if hidden { toggleHidden(); return }
        engine.dropIn(atX: NSEvent.mouseLocation.x)
        kick()
    }

    @objc private func talk() { engine.sayRandom(); kick() }

    // MARK: - schedule & reminders

    @objc private func openSchedule() {
        let portrait = ScheduleWindow.portrait(from: engine.frames["stand.normal.0"])
        if scheduleWindow == nil {
            let w = ScheduleWindow(store: schedule, avatar: portrait)
            w.onAdded = { [weak self] date in self?.eventAdded(on: date) }
            scheduleWindow = w
        }
        scheduleWindow?.show(avatar: portrait)
    }

    /// Lots of plans on one day, or many added in a row: the pet asks her to rest.
    private func eventAdded(on date: String) {
        let now = Date()
        recentAdds.append(now)
        recentAdds.removeAll { now.timeIntervalSince($0) > 600 }
        if schedule.count(on: date) >= 4 || recentAdds.count >= 5 {
            recentAdds.removeAll()
            engine.sayRest()
            kick()
        }
    }

    private func startReminders() {
        // anything that was due while the Mac was off and is older than an hour is skipped quietly
        for e in schedule.due(at: Date()) where Date().timeIntervalSince(e.due ?? Date()) > 3600 {
            schedule.markNotified(e.id)
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.checkReminders() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        reminderTimer = t
        checkReminders()
    }

    private func checkReminders() {
        let due = schedule.due(at: Date())
        guard !due.isEmpty else { return }
        if hidden { toggleHidden() }
        for e in due {
            schedule.markNotified(e.id)
            var text = "⏰ \(e.time)  \(e.title)"
            if !e.detail.isEmpty { text += "\n\(e.detail)" }
            engine.remind(text)
        }
        NSSound(named: "Glass")?.play()
        scheduleWindow?.push()
        kick()
    }

    /// Accessory apps have no menu bar, so give text fields the usual edit shortcuts.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ปิดหน้าต่าง", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc private func wake() { engine.wakeUp(); kick() }
    @objc private func sleepNow() { engine.goToSleep(); kick() }

    @objc private func setOutfit(_ sender: NSMenuItem) { wear(sender.tag) }

    @objc private func randomOutfit() {
        var n = Int.random(in: 0..<outfitNames.count)
        if n == Settings.outfit { n = (n + 1) % outfitNames.count }
        wear(n)
    }

    private func wear(_ n: Int) {
        guard let f = AppController.outfitFrames(n) else { return }
        Settings.outfit = n
        engine.setStyle(frames: f, scale: engine.scale)
        engine.newOutfit()
        resizeWindow()
        kick()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        Settings.size = sender.tag
        engine.setStyle(frames: engine.frames, scale: Settings.scale(sender.tag))
        resizeWindow()
    }

    @objc private func setSleep(_ sender: NSMenuItem) {
        Settings.sleepMinutes = Double(sender.tag)
        applySettings()
        engine.noteInteraction()
    }

    @objc private func toggleWalking() {
        Settings.walking.toggle()
        applySettings()
    }

    @objc private func editMessages() {
        _ = messages.lines("hello")
        NSWorkspace.shared.open([messages.userURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.enabled) }
    @objc private func quit() { NSApp.terminate(nil) }
}
