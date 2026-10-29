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
    static var letterShown: Bool {
        get { d.bool(forKey: "letterShown") }
        set { d.set(newValue, forKey: "letterShown") }
    }
    static var firstRunDone: Bool {
        get { d.bool(forKey: "firstRunDone") }
        set { d.set(newValue, forKey: "firstRunDone") }
    }
    static var language: String {  // "th" or "en"; Thai unless she picks English
        get { d.string(forKey: "language") ?? "th" }
        set { d.set(newValue, forKey: "language") }
    }
    static var seenNotes: [String] {  // notes from love.json he has already said
        get { d.stringArray(forKey: "seenNotes") ?? [] }
        set { d.set(newValue, forKey: "seenNotes") }
    }
    static var greeted: [String: String] {  // time of day ("morning", ...) -> the day he last said it
        get { d.dictionary(forKey: "greeted") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "greeted") }
    }
    static var announcedBuild: Int {  // the newest update he has already told her about
        get { d.integer(forKey: "announcedBuild") }
        set { d.set(newValue, forKey: "announcedBuild") }
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
            // a copy run straight from Downloads lives in a temporary folder that is gone after a restart
            guard let exe = Bundle.main.executablePath, !exe.contains("/AppTranslocation/") else { return }
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
    private var letterWindow: LetterWindow?
    private var cpuWindow: CPUWindow?
    private let love = Love()
    private var loveTimers: [Timer] = []
    private var update: Updater.Latest?  // a newer Pug that is ready to install
    private var updateTimer: Timer?
    private var guideWindow: GuideWindow?

    // MARK: - setup

    /// The pet's sprite atlas (he always wears the black suit).
    static func petFrames() -> [String: Frame]? {
        let res = Bundle.main.resourceURL!.appendingPathComponent("sprites")
        return Atlas.load(png: res.appendingPathComponent("pet.png"), json: res.appendingPathComponent("pet.json"))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let res = Bundle.main.resourceURL!
        messages = Messages.current()
        guard let fx = Atlas.load(png: res.appendingPathComponent("sprites/effects.png"),
                                  json: res.appendingPathComponent("sprites/effects.json")),
              let frames = AppController.petFrames()
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
        startUpdateChecks()
        startLove()

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
        if Settings.letterShown {
            engine.dropIn(atX: main.midX + CGFloat.random(in: -200...200), y: main.midY)
        } else {
            // first time on her Mac: the letter comes first, the pet is the gift inside it
            hidden = true
            panel.orderOut(nil)
            openLetter()
        }
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
        if hidden {  // nothing to draw: stop the timer until he is shown again
            timer?.invalidate(); timer = nil; timerFPS = 0
            return
        }
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

    /// Black-and-white copy of an image (the menu bar face), keeping its transparency.
    static func grayscale(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let y = UInt8(min(255, 0.3 * Double(px[i]) + 0.59 * Double(px[i + 1]) + 0.11 * Double(px[i + 2])))
            px[i] = y; px[i + 1] = y; px[i + 2] = y
        }
        return ctx.makeImage()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let f = engine.frames["stand.normal.0"],
           let head = f.image.cropping(to: CGRect(x: f.head.x - 30, y: f.head.y, width: 60, height: 60)),
           let mono = Self.grayscale(head) {
            let img = NSImage(cgImage: mono, size: NSSize(width: 18, height: 18))
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "Pug"
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
        add(L.t(hidden ? "Show" : "Hide"), #selector(toggleHidden))
        add(L.t("Call him"), #selector(summon))
        add(L.t("Say something"), #selector(talk))
        if love.latestNote() != nil { add(L.t("His last note…"), #selector(sayLastNote)) }
        add(L.t("Schedule / reminders…"), #selector(openSchedule))
        add(L.t("Anniversary letter…"), #selector(openLetter))
        add(L.t("How to play…"), #selector(openGuide))
        let asleep: [PetState] = [.sleeping, .deskSleeping, .yawning, .rubbing, .sittingDown]
        if asleep.contains(engine.state) { add(L.t("Wake up"), #selector(wake)) } else { add(L.t("Sleep now"), #selector(sleepNow)) }
        m.addItem(.separator())

        let size = NSMenu()
        for (i, n) in ["Small", "Medium", "Large"].enumerated() {
            add(L.t(n), #selector(setSize(_:)), tag: i, on: Settings.size == i, to: size)
        }
        let zi = NSMenuItem(title: L.t("Size"), action: nil, keyEquivalent: "")
        zi.submenu = size
        m.addItem(zi)

        let sleep = NSMenu()
        for minutes in [1, 3, 5, 10, 30] {
            add(L.t("%d min", minutes), #selector(setSleep(_:)), tag: minutes, on: Int(Settings.sleepMinutes) == minutes, to: sleep)
        }
        let li = NSMenuItem(title: L.t("Work or sleep when left alone"), action: nil, keyEquivalent: "")
        li.submenu = sleep
        m.addItem(li)
        add(L.t("Walk around"), #selector(toggleWalking), on: Settings.walking)
        let lang = NSMenu()
        for (i, (code, name)) in [("en", "English"), ("th", "ภาษาไทย")].enumerated() {
            add(name, #selector(setLanguage(_:)), tag: i, on: Settings.language == code, to: lang)
        }
        let gi = NSMenuItem(title: L.thai ? "ภาษา (Language)" : "Language (ภาษา)", action: nil, keyEquivalent: "")
        gi.submenu = lang
        m.addItem(gi)
        m.addItem(.separator())
        add(L.t("Edit lines…"), #selector(editMessages))
        add(L.t("Open at login"), #selector(toggleLogin), on: LoginItem.enabled)
        add(L.t("CPU usage…"), #selector(openCPU))
        add(update.map { L.t("Update Pug to %@…", $0.version) } ?? L.t("Check for updates…"), #selector(checkForUpdates))
        m.addItem(.separator())
        add(L.t("Quit"), #selector(quit))
        return m
    }

    @objc private func toggleHidden() {
        hidden.toggle()
        let m = NSEvent.mouseLocation
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless(); engine.dropIn(atX: m.x, y: m.y) }
        kick()
    }

    @objc private func summon() {
        if hidden { toggleHidden(); return }
        let m = NSEvent.mouseLocation
        engine.dropIn(atX: m.x, y: m.y)
        kick()
    }

    @objc private func talk() { engine.sayRandom(); kick() }

    // MARK: - letter

    @objc private func openLetter() {
        // after the first time, the newest monthly letter from love.json takes the original's place
        let monthly = Settings.letterShown ? love.latestLetter() : nil
        if let w = letterWindow, w.letter.title != (monthly?.letter.title ?? LetterWindow.load().title) {
            w.window.close()
            letterWindow = nil
        }
        if letterWindow == nil {
            let w = LetterWindow(custom: monthly?.letter)
            w.onOpen = { [weak self] in self?.giftOpened() }
            // closed before opening the gift the first time: still bring the pet out
            w.onClose = { [weak self] in if self?.hidden == true && !Settings.letterShown { self?.giftOpened() } }
            letterWindow = w
        }
        letterWindow?.show()
    }

    private func giftOpened() {
        let lines = letterWindow?.letter.after ?? LetterWindow.load().after
        if !Settings.letterShown || hidden {
            Settings.letterShown = true
            hidden = false
            panel.orderFrontRegardless()
            let b = bounds(near: NSEvent.mouseLocation)
            engine.arrive(atX: b.midX, y: b.midY, saying: lines)
            kick()
            // once he has said hello, show her what she can do with him
            let wait = 4 + Double(lines.count) * 4.5
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.openGuide() }
        } else {
            engine.sayLines(lines)
        }
        kick()
    }

    @objc private func openGuide() {
        if guideWindow == nil { guideWindow = GuideWindow() }
        guideWindow?.show()
    }

    // MARK: - schedule & reminders

    @objc private func openCPU() {
        if cpuWindow == nil { cpuWindow = CPUWindow(avatar: ScheduleWindow.portrait(from: engine.frames["stand.normal.0"])) }
        cpuWindow?.show()
    }

    /// Switch every word the app shows; open windows are closed so they reopen in the new language.
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let code = sender.tag == 1 ? "th" : "en"
        guard code != Settings.language else { return }
        Settings.language = code
        messages = Messages.current()
        for w in [scheduleWindow?.window, guideWindow?.window, letterWindow?.window, cpuWindow?.window] { w?.close() }
        scheduleWindow = nil; guideWindow = nil; letterWindow = nil; cpuWindow = nil
        setupEditMenu()
        engine.sayLines([messages.lines("hello").randomElement() ?? "Hi!"])
        kick()
    }

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
        for d in schedule.due(at: Date()) where Date().timeIntervalSince(d.at) > 3600 {
            schedule.markNotified(d.event.id, day: d.day)
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.checkReminders() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        reminderTimer = t
        checkReminders()
    }

    private func checkReminders() {
        // after a long Mac sleep, plans more than an hour overdue are skipped quietly, as at launch
        let now = Date()
        var due: [(event: ScheduleEvent, day: String, at: Date)] = [], skipped = false
        for d in schedule.due(at: now) {
            if now.timeIntervalSince(d.at) > 3600 { schedule.markNotified(d.event.id, day: d.day); skipped = true } else { due.append(d) }
        }
        guard !due.isEmpty else { if skipped { scheduleWindow?.push() }; return }
        if hidden { toggleHidden() }
        for d in due {
            schedule.markNotified(d.event.id, day: d.day)
            engine.remind(reminderText(d.event))
        }
        NSSound(named: "Glass")?.play()
        scheduleWindow?.push()
        kick()
    }

    /// "09:00  Exam", or "Tomorrow 09:00  Exam" when he reminds early.
    private func reminderText(_ e: ScheduleEvent) -> String {
        let early = [15: "In 15 min:", 60: "In 1 hour:", 1440: "Tomorrow"][e.ahead ?? 0]
        var text = (early.map { L.t($0) + " " } ?? "") + "\(e.time)  \(e.title)"
        if !e.detail.isEmpty { text += "\n\(e.detail)" }
        return text
    }

    /// Accessory apps have no menu bar, so give text fields the usual edit shortcuts.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.t("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L.t("Edit"))
        edit.addItem(withTitle: L.t("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L.t("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L.t("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L.t("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L.t("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L.t("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc private func wake() { engine.wakeUp(); kick() }
    @objc private func sleepNow() { engine.goToSleep(); kick() }

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

    // MARK: - love notes and anniversaries

    /// love.json comes in 20 seconds after launch and then every hour; every minute he looks for
    /// something to say: a new note from him, or the monthly anniversary.
    private func startLove() {
        let fetch = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.love.refresh { self?.everyMinute() } }
        let minute = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.everyMinute() }
        for t in [fetch, minute] {
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
        }
        loveTimers = [fetch, minute]
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.love.refresh { self?.everyMinute() } }
    }

    /// He only speaks up when she is at the Mac and he is awake, standing about and not mid-sentence.
    private var canSpeak: Bool {
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let free: [PetState] = [.idle, .walking, .working]
        return !hidden && !engine.isBusy && free.contains(engine.state) && away < 120 && letterWindow?.window.isVisible != true
    }

    private func everyMinute() {
        let now = Date()
        let months = love.anniversaryMonths(now: now)
        if months != nil, !hidden { engine.sparkleHearts(); kick() }
        guard canSpeak else { return }
        let today = Love.today(now)
        var greeted = Settings.greeted

        if let n = months, greeted["anniversary"] != today {
            greeted["anniversary"] = today
            Settings.greeted = greeted
            var lines = [(messages.lines("anniversary").randomElement() ?? "{n} months together today!")
                            .replacingOccurrences(of: "{n}", with: String(n))]
            if love.latestLetter(now: now)?.months == n, let l = messages.lines("newLetter").randomElement() { lines.append(l) }
            engine.sayLines(lines)
            kick()
            return
        }

        var seen = Settings.seenNotes
        if let note = love.unseenNotes(seen: Set(seen), now: now).first {
            seen.append(note.id)
            Settings.seenNotes = seen
            engine.sayLines(note.text.components(separatedBy: "\n\n"))
            kick()
            return
        }

    }

    @objc private func sayLastNote() {
        guard let note = love.latestNote() else { return }
        engine.sayLines(note.text.components(separatedBy: "\n\n"))
        kick()
    }

    // MARK: - updates

    /// Look for a new version a minute after launch, then every 6 hours; he says so once per version.
    private func startUpdateChecks() {
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.autoCheck() }
    }

    private func autoCheck() {
        Updater.fetchLatest { [weak self] latest in
            guard let self, let latest, latest.build > Updater.build else { return }
            self.update = latest
            let asleep: [PetState] = [.sleeping, .deskSleeping, .yawning, .rubbing, .sittingDown]
            guard latest.build > Settings.announcedBuild, !self.hidden, !self.engine.isBusy,
                  !asleep.contains(self.engine.state) else { return }
            Settings.announcedBuild = latest.build
            let line = self.messages.lines("update").randomElement() ?? "There's a new version of me!"
            self.engine.sayLines([line])
            self.kick()
        }
    }

    @objc private func checkForUpdates() {
        Updater.fetchLatest { [weak self] latest in
            guard let self else { return }
            guard let latest else {
                self.alert(L.t("Couldn't check for updates"), L.t("Check that you're online, then try again."))
                return
            }
            guard latest.build > Updater.build else {
                self.update = nil
                self.alert(L.t("You have the newest Pug"), L.t("Version %@.", Updater.version))
                return
            }
            self.update = latest
            let ok = self.alert(L.t("Pug %@ is ready", latest.version),
                                L.t("You have %@. Pug closes for a moment, updates, and comes right back. Your plans and settings stay as they are.", Updater.version),
                                buttons: [L.t("Update"), L.t("Later")])
            guard ok else { return }
            Updater.install(latest) { [weak self] message in
                self?.alert(L.t("Pug couldn't update"), message + "\n\n" + L.t("You can also download Pug.zip from github.com/Pug-03/Desktop-Pet-Pug and drag Pug into Applications."))
            }
        }
    }

    /// A small dialog; true when she picks the first button.
    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String] = [L.t("OK")]) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
