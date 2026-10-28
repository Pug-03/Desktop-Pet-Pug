import AppKit

/// Offline demo-video renderer: drives the real PetEngine with a scripted mouse and pipes frames to ffmpeg.
/// Run: Pug.app/Contents/MacOS/Pug --record <outDir> [clipName]
enum Recorder {
    enum Step {
        case wait(Double)
        case move(CGPoint, Double)
        case down, up
        case click
        case act((PetEngine) -> Void)
        case outfit(Int)
    }

    struct Clip {
        let name: String
        let caption: String
        var startX: CGFloat = 640
        var walking = false
        let steps: [Step]
    }

    static let W = 1280, H = 720
    static let fps = 30.0
    static let screen = CGRect(x: 0, y: 64, width: 1280, height: 656)

    static func clips() -> [Clip] {
        let floor = screen.minY
        func at(_ x: CGFloat, _ h: CGFloat) -> CGPoint { CGPoint(x: x, y: floor + h) }
        let chest = at(640, 220), head = at(640, 300), away = CGPoint(x: 1000, y: 560)
        return [
            Clip(name: "01_hello", caption: "เปิดแอป → ตกลงมาจากข้างบน แล้วโบกมือทักทาย", steps: [
                .act { $0.dropIn(atX: 640) }, .wait(6.5),
            ]),
            Clip(name: "02_idle_walk", caption: "ปล่อยไว้เฉยๆ → ยืนหายใจ กะพริบตา แล้วค่อยๆ เดินเล่นไปมา", startX: 380, walking: true, steps: [
                .wait(2.5), .act { $0.walk(toX: 900) }, .wait(9), .act { $0.walk(toX: 560) }, .wait(7),
            ]),
            Clip(name: "03_poke_tickle", caption: "คลิก (จิ้ม) 1 ที → จั๊กจี้ หัวเราะคิกคัก", steps: [
                .move(away, 0), .wait(0.8), .move(chest, 0.8), .wait(0.3), .click, .wait(2.2),
                .move(at(650, 200), 0.3), .click, .wait(2.5),
            ]),
            Clip(name: "04_poke_dizzy", caption: "จิ้มรัวๆ หลายทีติดกัน → มึนหัว ตาเป็นกากบาท ดาววนหัว", steps: [
                .move(away, 0), .wait(0.5), .move(chest, 0.7),
                .click, .wait(0.35), .click, .wait(0.35), .click, .wait(0.35), .click, .wait(0.35), .click, .wait(0.35), .click,
                .wait(4.5),
            ]),
            Clip(name: "05_hold_lift", caption: "กดค้างไว้ → ถูกยกขึ้น ขาห้อยแกว่งตามเมาส์ ลากไปไหนก็ได้", steps: [
                .move(away, 0), .wait(0.5), .move(head, 0.8), .down, .wait(0.6),
                .move(at(640, 470), 1.0), .wait(0.6),
                .move(at(900, 470), 1.1), .wait(1.0),
                .move(at(400, 500), 1.4), .wait(2.8),
                .move(at(400, 330), 0.6), .up, .wait(2.5),
            ]),
            Clip(name: "06_drop", caption: "ยกขึ้นสูงๆ แล้วปล่อย → ตกลงพื้น ตัวยุบแล้วเด้ง (ตกแรงๆ จะมึน)", steps: [
                .move(away, 0), .wait(0.4), .move(head, 0.7), .down, .wait(0.4),
                .move(at(640, 420), 0.8), .wait(0.8), .up, .wait(2.2),
                .move(head, 0.6), .down, .wait(0.3),
                .move(at(640, 590), 0.9), .wait(0.6), .up, .wait(5),
            ]),
            Clip(name: "07_shake_dizzy", caption: "ยกแล้วเขย่าแรงๆ → ตกใจ เหงื่อตก แล้วมึนหัวตอนลงพื้น", steps: [
                .move(away, 0), .wait(0.4), .move(head, 0.7), .down, .wait(0.3),
                .move(at(640, 470), 0.6), .wait(0.3),
                .move(at(840, 470), 0.12), .move(at(440, 470), 0.16),
                .move(at(840, 470), 0.16), .move(at(440, 470), 0.16),
                .move(at(840, 470), 0.16), .move(at(440, 470), 0.16),
                .move(at(640, 470), 0.12), .wait(1.2), .up, .wait(5),
            ]),
            Clip(name: "08_throw", caption: "ลากแล้วเหวี่ยงปล่อย → ลอยไปชนขอบจอแล้วเด้งกลับ", startX: 400, steps: [
                .move(away, 0), .wait(0.4), .move(at(400, 270), 0.7), .down, .wait(0.3),
                .move(at(450, 400), 0.5), .wait(0.4), .move(at(780, 560), 0.22), .up,
                .wait(4.5),
            ]),
            Clip(name: "09_goodnight", caption: "ไม่มีใครเล่นด้วยสักพัก → หาว บอกฝันดี คิดถึง โทรมาได้ แล้วนอนหลับ Zzz", steps: [
                .wait(1), .act { $0.goToSleep() }, .wait(20),
            ]),
            Clip(name: "11_outfits", caption: "เมนู → เปลี่ยนชุด: เปลี่ยนแค่เสื้อ กางเกงกับรองเท้าเหมือนเดิม (17 แบบ)", steps: [
                .wait(1.2), .outfit(2), .wait(2.4), .outfit(5), .wait(2.4), .outfit(8), .wait(2.4),
                .outfit(12), .wait(2.4), .outfit(14), .wait(2.4), .outfit(16), .wait(2.4), .outfit(0), .wait(2.4),
            ]),
            Clip(name: "12_reminder", caption: "ถึงเวลาที่ตั้งไว้ในตาราง → ลุกขึ้นมาเตือน (จิ้มเพื่อรับทราบ)", steps: [
                .act { $0.goToSleep(immediately: true) }, .move(away, 0), .wait(2),
                .act { $0.remind("⏰ 15:00  ส่งงาน\nรายงานบทที่ 3") }, .wait(6),
                .move(chest, 0.7), .click, .wait(2.5),
            ]),
            Clip(name: "10_wake", caption: "จิ้มตอนกำลังหลับ → ตื่นงัวเงีย", steps: [
                .act { $0.goToSleep(immediately: true) }, .move(away, 0), .wait(3),
                .move(at(560, 30), 0.8), .wait(0.3), .click, .wait(4.5),
            ]),
        ]
    }

    static func run(outDir: URL, only: String?) -> Int32 {
        let res = Bundle.main.resourceURL!
        guard let fx = Atlas.load(png: res.appendingPathComponent("sprites/effects.png"), json: res.appendingPathComponent("sprites/effects.json"))
        else { print("missing sprites"); return 1 }
        let msgs = Messages(fixed: Messages.parse(res.appendingPathComponent("messages.json")) ?? [:])
        let renderer = Renderer(effects: fx)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for clip in clips() where only == nil || clip.name == only {
            guard let frames = Atlas.load(png: res.appendingPathComponent("sprites/pet.png"),
                                          json: res.appendingPathComponent("sprites/pet.json"))
            else { return 1 }
            let scale: CGFloat = 0.95
            let e = PetEngine(frames: frames, scale: scale, start: CGPoint(x: clip.startX, y: screen.minY), seed: 7,
                              screenBounds: { _ in screen }, messages: { msgs.lines($0) })
            e.walkingEnabled = clip.walking
            e.sleepAfter = 1e9
            e.chatEvery = 1e9...1e9 + 1
            e.tick(0.01)
            let url = outDir.appendingPathComponent("\(clip.name).mp4")
            print("recording \(url.lastPathComponent)")
            if !record(clip, e, renderer, to: url) { return 1 }
        }
        return 0
    }

    private static func record(_ clip: Clip, _ e: PetEngine, _ r: Renderer, to url: URL) -> Bool {
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/ffmpeg")
        ff.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "\(Int(fps))",
                        "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", url.path]
        let pipe = Pipe()
        ff.standardInput = pipe
        do { try ff.run() } catch { print("ffmpeg failed: \(error)"); return false }

        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }

        var cursor = CGPoint(x: 1100, y: 500)
        var down = false
        var ripple: Double = 99
        var steps = clip.steps[...]
        var stepT = 0.0
        var moveFrom = cursor
        let dt = 1 / fps
        var total = 0.0

        while let step = steps.first {
            var advance = false
            switch step {
            case .wait(let d):
                stepT += dt
                advance = stepT >= d
            case .move(let p, let d):
                if stepT == 0 { moveFrom = cursor }
                stepT += dt
                let k = d <= 0 ? 1 : min(1, stepT / d)
                let s = k * k * (3 - 2 * k)
                cursor = CGPoint(x: moveFrom.x + (p.x - moveFrom.x) * s, y: moveFrom.y + (p.y - moveFrom.y) * s)
                if down { e.pointerMoved(cursor) }
                advance = k >= 1
            case .down:
                e.pointerDown(cursor); down = true; ripple = 0; advance = true
            case .up:
                e.pointerUp(cursor); down = false; advance = true
            case .click:
                if stepT == 0 { e.pointerDown(cursor); down = true; ripple = 0 }
                stepT += dt
                if stepT >= 0.08 { e.pointerUp(cursor); down = false; advance = true }
            case .act(let f):
                f(e); advance = true
            case .outfit(let n):
                if let f = AppController.outfitFrames(n) {
                    e.setStyle(frames: f, scale: e.scale)
                    e.newOutfit()
                }
                advance = true
            }
            if advance { steps = steps.dropFirst(); stepT = 0 }
            switch step {
            case .down, .up, .act, .outfit: continue
            default: break
            }

            e.tick(dt)
            total += dt
            ripple += dt
            drawBackground(ctx)
            r.draw(e, in: ctx, origin: .zero, screen: screen, pixel: 1)
            drawCaption(ctx, clip.caption)
            drawCursor(ctx, cursor, pressed: down, ripple: ripple)
            guard let data = ctx.data else { return false }
            pipe.fileHandleForWriting.write(Data(bytes: data, count: W * H * 4))
        }
        // short tail so the last action settles
        for _ in 0..<Int(fps * 0.5) {
            e.tick(dt)
            drawBackground(ctx)
            r.draw(e, in: ctx, origin: .zero, screen: screen, pixel: 1)
            drawCaption(ctx, clip.caption)
            drawCursor(ctx, cursor, pressed: false, ripple: 99)
            pipe.fileHandleForWriting.write(Data(bytes: ctx.data!, count: W * H * 4))
        }
        try? pipe.fileHandleForWriting.close()
        ff.waitUntilExit()
        return ff.terminationStatus == 0
    }

    // MARK: - scenery

    private static func drawBackground(_ ctx: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(srgbRed: 0.98, green: 0.90, blue: 0.93, alpha: 1),
                      CGColor(srgbRed: 0.86, green: 0.91, blue: 0.98, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(H)), options: [])
        // a simple dock-like shelf the pet stands on
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 240, y: 8, width: 800, height: 48), cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
        let icons: [CGColor] = [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.62, alpha: 1), CGColor(srgbRed: 0.99, green: 0.82, blue: 0.5, alpha: 1),
            CGColor(srgbRed: 0.6, green: 0.85, blue: 0.68, alpha: 1), CGColor(srgbRed: 0.58, green: 0.74, blue: 0.98, alpha: 1),
            CGColor(srgbRed: 0.78, green: 0.66, blue: 0.96, alpha: 1),
        ]
        for i in 0..<10 {
            ctx.setFillColor(icons[i % icons.count])
            ctx.addPath(CGPath(roundedRect: CGRect(x: 268 + i * 76, y: 14, width: 36, height: 36), cornerWidth: 9, cornerHeight: 9, transform: nil))
            ctx.fillPath()
        }
    }

    private static func drawCaption(_ ctx: CGContext, _ text: String) {
        let base = NSFont.systemFont(ofSize: 26, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 26) } ?? base
        let str = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 0.22, green: 0.14, blue: 0.24, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let box = CGRect(x: 32, y: CGFloat(H) - 92, width: b.width + 44, height: 58)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.fillPath()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: box.minX + 22, y: box.minY + 19)
        CTLineDraw(line, ctx)
    }

    private static func drawCursor(_ ctx: CGContext, _ p: CGPoint, pressed: Bool, ripple: Double) {
        if ripple < 0.45 {
            let k = CGFloat(ripple / 0.45)
            ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.35, blue: 0.5, alpha: 1 - k))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: p.x - 8 - 22 * k, y: p.y - 8 - 22 * k, width: 16 + 44 * k, height: 16 + 44 * k))
        }
        if pressed {
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.35, blue: 0.5, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
        }
        let s: CGFloat = 1.5
        let pts: [CGPoint] = [(0, 0), (0, -17), (4, -13), (7, -20), (10, -19), (7, -12), (12, -12)]
            .map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(.black)
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}
