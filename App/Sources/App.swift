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

    // MARK: - setup

    func applicationDidFinishLaunching(_ note: Notification) {
        let res = Bundle.main.resourceURL!
        messages = Messages(bundled: res.appendingPathComponent("messages.json"))
        guard let fx = Atlas.load(png: res.appendingPathComponent("sprites/effects.png"),
                                  json: res.appendingPathComponent("sprites/effects.json")),
              let frames = Atlas.load(png: res.appendingPathComponent("sprites/pet.png"),
                                      json: res.appendingPathComponent("sprites/pet.json"))
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
        panel.level = .floating
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

        if !Settings.firstRunDone {
            Settings.firstRunDone = true
            LoginItem.set(true)
        } else if LoginItem.enabled {
            LoginItem.set(true)  // refresh the path in case the app was moved
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
        if let s = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) { return s.visibleFrame }
        // nearest screen horizontally (the pet walks along the bottom)
        let best = screens.min { a, b in
            abs(a.frame.midX - p.x) + abs(a.frame.midY - p.y) < abs(b.frame.midX - p.x) + abs(b.frame.midY - p.y)
        }
        return best?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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

    @objc private func screensChanged() { engine.noteInteraction() }

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
        if engine.state == .sleeping { add("ปลุก", #selector(wake)) } else { add("ให้นอนเลย", #selector(sleepNow)) }
        m.addItem(.separator())

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
    @objc private func quit() { NSApp.terminate(nil) }
}
