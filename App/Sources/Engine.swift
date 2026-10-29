import CoreGraphics
import Foundation

/// Small deterministic PRNG so recordings are repeatable.
final class Rand {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(1 << 53)
    }
    func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    func chance(_ p: Double) -> Bool { next() < p }
    func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[min(a.count - 1, Int(next() * Double(a.count)))] }
}

enum PetState {
    case idle, walking, tickled, held, falling, landing, dizzy, talking
    case yawning, rubbing, sittingDown, sleeping, waking
    case working, deskSleeping
}

enum TalkPose { case wave, waveShy, love, shy, alert }

struct Particle {
    var sprite: String
    var pos: CGPoint
    var vel: CGVector
    var life: Double
    var age: Double = 0
    var size: CGFloat = 1
    var wobble: Double = 0
}

struct Bubble {
    var text: String
    var life: Double
    var age: Double = 0
}

/// All of the pet's behaviour. Screen coordinates are points with y up (AppKit convention).
/// It knows nothing about windows, so the live app and the video recorder share it.
final class PetEngine {
    // configuration
    private(set) var frames: [String: Frame]
    private(set) var scale: CGFloat
    var sleepAfter: Double = 180
    var walkingEnabled = true
    private var dropScreen: CGRect?     // the screen he is dropping onto, until he lands
    var chatEvery: ClosedRange<Double> = 1200...2400
    /// Bedtime: only then does he go to bed (or nod off at the desk); the rest of the day he works.
    var isNight: () -> Bool = {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 22 || h < 6
    }
    /// Seconds of work before he gets up for a walk, and how long that break lasts.
    var workSession: ClosedRange<Double> = 3300...3900
    var breakLength: ClosedRange<Double> = 120...300
    /// How often he turns round from the laptop to cheer her on.
    var cheerEvery: ClosedRange<Double> = 300...600
    /// Seconds of working late before he falls asleep at the desk.
    var nodOffAfter: ClosedRange<Double> = 90...240
    let screenBounds: (CGPoint) -> CGRect
    let messages: (String) -> [String]
    let rng: Rand

    // pose
    private(set) var state: PetState = .idle
    private(set) var t: Double = 0
    private(set) var clock: Double = 0
    private var lastDt: Double = 0
    /// The floor moved under the pet (Dock shown or hidden): ease to it instead of jumping.
    private var gliding = false
    private(set) var pivot: CGPoint
    private(set) var grabArt: CGPoint?
    private(set) var rotation: CGFloat = 0
    private(set) var sx: CGFloat = 1
    private(set) var sy: CGFloat = 1
    private(set) var facing: CGFloat = 1
    private(set) var frameKey = "stand.normal.0"
    private(set) var particles: [Particle] = []
    private(set) var bubble: Bubble?
    private(set) var shaken = false

    private var vel = CGVector.zero
    private var angVel: CGFloat = 0
    private var idleFor = 3.0
    private var nextBlink = 2.0
    private var nextChat: Double
    private var nextSpark = 0.0
    private var walkTarget: CGFloat = 0
    private var lastInteraction = 0.0
    private var pokes: [Double] = []
    private var fallTop: CGFloat = 0
    private var landingImpact: CGFloat = 0
    private var dizzyAfterLanding = false
    private var greetAfterLanding = false
    private var talkQueue: [(String, TalkPose)] = []
    private var talkPose = TalkPose.wave
    private var afterTalk: PetState = .idle
    private var pendingTalk: [(String, TalkPose)] = []
    private var lastSaid: [String: String] = [:]
    private var deskPose = "type"
    private var poseUntil = 0.0
    private var workUntil = 0.0
    private var breakUntil = 0.0
    private var nodOffAt = 0.0
    private var nextCheer = 0.0
    private var lastCode = -1

    // pointer
    private(set) var pressed = false
    private var pressAt = 0.0
    private var pressPoint = CGPoint.zero
    private var pointer = CGPoint.zero
    private var prevPivot = CGPoint.zero
    private var cursorVel = CGVector.zero
    private var shakeSign: CGFloat = 0
    private var shakeFlips: [Double] = []

    init(frames: [String: Frame], scale: CGFloat, start: CGPoint, seed: UInt64,
         screenBounds: @escaping (CGPoint) -> CGRect, messages: @escaping (String) -> [String]) {
        self.frames = frames
        self.scale = scale
        self.pivot = start
        self.screenBounds = screenBounds
        self.messages = messages
        self.rng = Rand(seed: seed)
        self.nextChat = 0
        nextChat = rng.range(chatEvery.lowerBound, chatEvery.upperBound)
    }

    // MARK: - geometry

    var frame: Frame { frames[frameKey] ?? frames["stand.normal.0"]! }
    var pivotArt: CGPoint { grabArt ?? frame.anchor }
    var drawFacing: CGFloat { state == .walking ? facing : 1 }

    func toScreen(_ a: CGPoint) -> CGPoint {
        let p = pivotArt
        let lx = (a.x - p.x) * scale * drawFacing * sx
        let ly = -(a.y - p.y) * scale * sy
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: pivot.x + lx * c - ly * s, y: pivot.y + lx * s + ly * c)
    }

    func toArt(_ q: CGPoint) -> CGPoint {
        let dx = q.x - pivot.x, dy = q.y - pivot.y
        let c = cos(-rotation), s = sin(-rotation)
        let lx = dx * c - dy * s, ly = dx * s + dy * c
        let p = pivotArt
        return CGPoint(x: lx / (scale * drawFacing * sx) + p.x, y: p.y - ly / (scale * sy))
    }

    var feet: CGPoint { toScreen(frame.anchor) }
    var headPoint: CGPoint { toScreen(frame.head) }
    var bodyCenter: CGPoint {
        let f = frame
        return toScreen(CGPoint(x: f.anchor.x, y: (f.anchor.y + f.head.y) / 2))
    }

    func hitTest(_ q: CGPoint) -> Bool {
        let a = toArt(q)
        let x = Int(a.x.rounded(.down)), y = Int(a.y.rounded(.down))
        let f = frame
        for dy in -1...1 { for dx in -1...1 where f.opaque(x + dx, y + dy) { return true } }
        return false
    }

    /// Stars spin around the head while dizzy (or while being shaken).
    var starsPhase: Double? { state == .dizzy || (state == .held && shaken) ? clock : nil }

    var preferredFPS: Double {
        switch state {
        case _ where gliding: return 60
        case .held, .falling, .landing, .tickled: return 60
        case .sleeping, .deskSleeping: return particles.isEmpty && bubble == nil ? 8 : 20
        case .idle: return particles.isEmpty && bubble == nil ? 15 : 30
        default: return 30
        }
    }

    var isBusy: Bool { pressed || state == .held || state == .falling }

    // MARK: - external controls

    func setStyle(frames: [String: Frame], scale: CGFloat) {
        let keepFeet = feet
        self.frames = frames
        self.scale = scale
        grabArt = nil
        rotation = 0; sx = 1; sy = 1
        pivot = keepFeet
        go(.idle)
    }

    /// Drop in from the top of the screen that holds (x, y); without y, the screen he is on.
    func dropIn(atX x: CGFloat, y: CGFloat? = nil) {
        let b = screenBounds(CGPoint(x: x, y: y ?? pivot.y))
        dropScreen = b  // the start point is above this screen, maybe inside the one stacked over it
        grabArt = nil
        rotation = 0; sx = 1; sy = 1
        pivot = CGPoint(x: min(max(x, b.minX + 60), b.maxX - 60), y: b.maxY + 20)
        vel = CGVector(dx: 0, dy: -200)
        fallTop = pivot.y
        greetAfterLanding = true
        frameKey = "fall.0"
        go(.falling)
    }

    /// The gift is opened: drop in and say the lines from the letter, with hearts.
    func arrive(atX x: CGFloat, y: CGFloat? = nil, saying lines: [String]) {
        dropIn(atX: x, y: y)
        greetAfterLanding = false
        pendingTalk = lines.enumerated().map { ($0.element, $0.offset % 2 == 0 ? TalkPose.wave : .love) }
    }

    /// Say these lines in turn (the letter's closing words, when it is read again).
    func sayLines(_ lines: [String]) {
        guard !isBusy, !lines.isEmpty else { return }
        lastInteraction = clock
        startTalk(lines.map { ($0, TalkPose.love) }, then: .idle)
    }

    func walk(toX x: CGFloat) {
        guard grabArt == nil else { return }
        walkTarget = x
        facing = x >= pivot.x ? 1 : -1
        go(.walking)
    }

    func goToSleep(immediately: Bool = false) {
        guard !isBusy else { return }
        lastInteraction = clock - sleepAfter
        if immediately {
            frameKey = "sit.sleep.0"
            go(.sleeping)
        } else {
            go(.yawning)
        }
    }

    func wakeUp() {
        lastInteraction = clock
        if [.sleeping, .sittingDown, .rubbing, .yawning].contains(state) { go(.waking) }
        if state == .deskSleeping { wakeAtDesk() }
        if state == .talking && afterTalk == .rubbing { talkQueue.removeAll(); bubble = nil; go(.idle) }
    }

    func sayRandom() {
        guard !isBusy, state != .sleeping, state != .deskSleeping else { return }
        lastInteraction = clock
        startTalk([(pick("random") ?? "Miss you", rng.chance(0.5) ? .love : .wave)], then: .idle)
    }

    func noteInteraction() { lastInteraction = clock }

    /// A reminder from the schedule: hop up (waking if asleep), then wave with the message.
    func remind(_ text: String) {
        lastInteraction = clock
        if state == .talking && talkPose == .alert {
            talkQueue.append((text, .alert))
            return
        }
        pendingTalk.append((text, .alert))
        if isBusy || state == .falling || state == .landing { return }
        talkQueue.removeAll()
        bubble = nil
        grabArt = nil
        rotation = 0; sx = 1; sy = 1
        vel = CGVector(dx: 0, dy: 640)
        fallTop = feet.y
        spawn("bang", at: headPoint + CGVector(dx: 26 * scale, dy: 6 * scale), vel: CGVector(dx: 0, dy: 30), life: 0.8)
        frameKey = "fall.0"
        go(.falling)
    }

    /// Too many things on one day: tell her to rest.
    func sayRest() {
        guard !isBusy, state != .sleeping, state != .deskSleeping, !(state == .talking && talkPose == .alert) else { return }
        lastInteraction = clock
        startTalk([(pick("rest") ?? "Take a break, okay?", .love)], then: .idle)
    }

    // MARK: - pointer

    @discardableResult
    func pointerDown(_ p: CGPoint) -> Bool {
        guard hitTest(p), state != .falling else { return false }
        pressed = true
        pressAt = clock
        pressPoint = p
        pointer = p
        lastInteraction = clock
        return true
    }

    func pointerMoved(_ p: CGPoint) {
        pointer = p
        if pressed && state != .held && hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 5 { beginHold() }
        if state == .held { pivot = p }
    }

    func pointerUp(_ p: CGPoint) {
        pointer = p
        guard pressed else { return }
        pressed = false
        lastInteraction = clock
        if state == .held { release() } else { poke() }
    }

    private func beginHold() {
        let off = max(-8, min(8, toArt(pointer).x - frame.anchor.x))
        talkQueue.removeAll()
        rotation = 0; angVel = 0; sx = 1; sy = 1
        go(.held)
        frameKey = "held.surprised.0"
        let f = frame
        grabArt = CGPoint(x: f.anchor.x + off, y: f.head.y + (f.face.y - f.head.y) * 0.45)
        pivot = pointer
        prevPivot = pointer
        cursorVel = .zero
        shaken = false
        shakeFlips.removeAll()
        if rng.chance(0.5) { spawn("bang", at: headPoint + CGVector(dx: 22 * scale, dy: 4 * scale), vel: CGVector(dx: 0, dy: 20), life: 0.7) }
    }

    private func release() {
        let speed = hypot(cursorVel.dx, cursorVel.dy)
        let k = speed > 1800 ? 1800 / speed : 1
        vel = CGVector(dx: cursorVel.dx * k, dy: cursorVel.dy * k)
        fallTop = feet.y
        go(.falling)
    }

    private func poke() {
        switch state {
        case .sleeping, .sittingDown:
            go(.waking); return
        case .deskSleeping:
            wakeAtDesk(); return
        case .working:
            // a poke at work: he turns round to look, says something, then carries on
            setDeskPose(rng.chance(0.5) ? "surprised" : "turn", for: 2.6)
            nodOffAt = max(nodOffAt, clock + 20)
            if bubble == nil || rng.chance(0.5) { say("work") }
            return
        case .waking, .held, .falling, .landing:
            return
        default:
            break
        }
        if state == .talking && talkPose == .alert {
            // a poke acknowledges the reminder
            talkQueue.removeAll { $0.1 == .alert }
            bubble = nil
        }
        talkQueue.removeAll()
        pokes.append(clock)
        pokes.removeAll { clock - $0 > 3.5 }
        if pokes.count >= 6 {
            pokes.removeAll()
            say("dizzy")
            startDizzy()
            return
        }
        if pokes.count == 3 { say("tickle") }
        sx = 1; sy = 1
        rotation = 0
        go(.tickled)
    }

    // MARK: - tick

    func tick(_ rawDt: Double) {
        let dt = min(max(rawDt, 0), 1.0 / 15)
        lastDt = dt
        clock += dt
        t += dt
        if pressed && state != .held && clock - pressAt > 0.3 { beginHold() }

        switch state {
        case .idle: idle()
        case .walking: walking(dt)
        case .tickled: tickled()
        case .held: held(dt)
        case .falling: falling(dt)
        case .landing: landing()
        case .dizzy: dizzy()
        case .talking: talking()
        case .working: working()
        case .deskSleeping: deskSleeping()
        case .yawning:
            snap()
            frameKey = "yawn.\(Int(t * 2.4) % 4)"
            if t > 3.3 {
                let lines = messages("goodnight")
                let poses: [TalkPose] = [.waveShy, .love, .shy]
                startTalk(lines.enumerated().map { ($0.element, poses[$0.offset % poses.count]) }, then: .rubbing)
            }
        case .rubbing:
            snap()
            frameKey = "rub.\(Int(t * 4) % 2)"
            if t > 1.5 { go(.sittingDown) }
        case .sittingDown:
            snap()
            frameKey = "sit.sleepy.0"
            let k = CGFloat(exp(-t * 8) * cos(t * 18))
            sy = 1 - 0.12 * k; sx = 1 + 0.08 * k
            if t > 1.0 { sx = 1; sy = 1; go(.sleeping) }
        case .sleeping:
            snap()
            frameKey = "sit.sleep.\(Int(clock / 1.4) % 2)"
            if clock > nextSpark {
                let big = Int(clock / 1.5) % 2 == 0
                spawn(big ? "z_l" : "z_s", at: headPoint + CGVector(dx: 18 * scale, dy: 2 * scale),
                      vel: CGVector(dx: 12 * scale, dy: 22 * scale), life: 2.6, wobble: 1)
                nextSpark = clock + 1.5
            }
        case .waking:
            snap()
            if t < 1.0 {
                frameKey = Int(t * 5) % 2 == 0 ? "sit.blink.0" : "sit.sleepy.0"
            } else {
                frameKey = "stand.sleepy.\(Int(clock / 0.9) % 2)"
                if bubble == nil && t < 1.2 { say("wake") }
            }
            if t > 3.0 { lastInteraction = clock; toIdle(2) }
        }

        updateParticles(dt)
        if var b = bubble {
            b.age += dt
            bubble = b.age > b.life ? nil : b
        }
        keepOnScreen()
    }

    // MARK: - states

    private func go(_ s: PetState) {
        state = s
        t = 0
    }

    private func toIdle(_ wait: Double? = nil) {
        sx = 1; sy = 1; rotation = 0
        idleFor = wait ?? rng.range(3, 7)
        go(.idle)
    }

    private var breath: Int { Int(clock / 0.9) % 2 }

    private var eyes: String {
        if clock >= nextBlink {
            if clock < nextBlink + 0.14 { return "blink" }
            nextBlink = clock + rng.range(2, 5.5)
        }
        return "normal"
    }

    private func idle() {
        snap()
        frameKey = "stand.\(eyes).\(breath)"
        guard t > idleFor else { return }
        if clock - lastInteraction > sleepAfter && isNight() {
            go(.yawning)
        } else if clock - lastInteraction > sleepAfter && clock > breakUntil {
            startWork()
        } else if clock > nextChat {
            nextChat = clock + rng.range(chatEvery.lowerBound, chatEvery.upperBound)
            startTalk([(pick("random") ?? "Miss you", rng.chance(0.5) ? .love : .wave)], then: .idle)
        } else if walkingEnabled && rng.chance(0.6) {
            let b = screenBounds(pivot)
            let m = 45 * scale
            var x = pivot.x + CGFloat(rng.range(80, 380)) * (rng.chance(0.5) ? 1 : -1)
            if x < b.minX + m || x > b.maxX - m { x = pivot.x - (x - pivot.x) }
            walk(toX: min(max(x, b.minX + m), b.maxX - m))
        } else {
            toIdle()
        }
    }

    private func walking(_ dt: Double) {
        snap()
        frameKey = "walk.\(eyes).\(Int(t * 5) % 8)"
        pivot.x += facing * 140 * scale * CGFloat(dt)
        let b = screenBounds(pivot)
        if pivot.y > b.minY + 4 * scale {  // walked off the end of the Dock: hop down
            vel = CGVector(dx: facing * 140 * scale, dy: 120)
            fallTop = pivot.y
            go(.falling)
            return
        }
        let m = 32 * scale
        let arrived = facing > 0 ? pivot.x >= walkTarget : pivot.x <= walkTarget
        if arrived || pivot.x < b.minX + m || pivot.x > b.maxX - m { toIdle() }
    }

    private func tickled() {
        snap()
        frameKey = "laugh.\(Int(t * 10) % 4)"
        sy = 1 + 0.035 * CGFloat(sin(t * 32))
        sx = 1 / sy
        if clock > nextSpark {
            let h = headPoint
            spawn(rng.chance(0.55) ? "heart_s" : "sparkle",
                  at: CGPoint(x: h.x + CGFloat(rng.range(-30, 30)) * scale, y: h.y - CGFloat(rng.range(0, 16)) * scale),
                  vel: CGVector(dx: rng.range(-15, 15), dy: rng.range(35, 60)), life: 0.9)
            nextSpark = clock + 0.16
        }
        if t > 1.4 { toIdle(rng.range(2, 4)) }
    }

    private func held(_ dt: Double) {
        let raw = CGVector(dx: (pivot.x - prevPivot.x) / CGFloat(dt), dy: (pivot.y - prevPivot.y) / CGFloat(dt))
        prevPivot = pivot
        let prevVel = cursorVel
        cursorVel = CGVector(dx: cursorVel.dx * 0.5 + raw.dx * 0.5, dy: cursorVel.dy * 0.5 + raw.dy * 0.5)
        let ax = max(-30000, min(30000, (cursorVel.dx - prevVel.dx) / CGFloat(dt)))

        // pendulum hanging from the grab point
        let f = frame
        let L = max(30, (f.anchor.y - (grabArt?.y ?? 0)) * scale * 0.6)
        let g: CGFloat = 2600
        let acc = -(g / L) * sin(rotation) - (ax / L) * cos(rotation) * 0.6 - 3 * angVel
        angVel += acc * CGFloat(dt)
        rotation = max(-1.1, min(1.1, rotation + angVel * CGFloat(dt)))

        // shaking detection: quick left/right reversals
        if abs(cursorVel.dx) > 650 {
            let s: CGFloat = cursorVel.dx > 0 ? 1 : -1
            if s != shakeSign { shakeFlips.append(clock); shakeSign = s }
        }
        shakeFlips.removeAll { clock - $0 > 1.5 }
        if shakeFlips.count >= 5 { shaken = true }

        let fast = hypot(cursorVel.dx, cursorVel.dy) > 900
        let face = shaken ? "dizzy" : fast ? "scared" : (t > 2.5 ? "happy" : "surprised")
        frameKey = "held.\(face).\(Int(t * (fast ? 12 : 7)) % 4)"
        if fast && clock > nextSpark {
            spawn("sweat", at: headPoint + CGVector(dx: 24 * scale, dy: -8 * scale), vel: CGVector(dx: 30, dy: 30), life: 0.6)
            nextSpark = clock + 0.35
        }
    }

    private func falling(_ dt: Double) {
        frameKey = "fall.\(Int(t * 10) % 4)"
        vel.dy -= 2600 * CGFloat(dt)
        pivot.x += vel.dx * CGFloat(dt)
        pivot.y += vel.dy * CGFloat(dt)
        rotation *= CGFloat(exp(-7 * dt))
        let b = dropScreen ?? screenBounds(feet)
        let m = 20 * scale
        let f = feet
        if f.x < b.minX + m { pivot.x += b.minX + m - f.x; vel.dx = abs(vel.dx) * 0.55 }
        if f.x > b.maxX - m { pivot.x -= f.x - (b.maxX - m); vel.dx = -abs(vel.dx) * 0.55 }
        if headPoint.y > b.maxY + 40 && vel.dy > 0 { vel.dy *= -0.3 }
        fallTop = max(fallTop, f.y)
        if feet.y <= b.minY { land(b) }
    }

    private func land(_ b: CGRect) {
        let f = feet
        let impact = -vel.dy
        grabArt = nil
        rotation = 0
        pivot = CGPoint(x: f.x, y: b.minY)
        vel = .zero
        landingImpact = impact
        dropScreen = nil
        // a drop-in from the top of a tall screen lands hard too, but then he says hello instead
        dizzyAfterLanding = shaken || (impact > 2300 && !greetAfterLanding)
        shaken = false
        frameKey = "stand.surprised.0"
        if impact > 500 {
            for s in [-1.0, 1.0] {
                spawn("puff", at: CGPoint(x: f.x + CGFloat(s) * 18 * scale, y: b.minY + 6 * scale),
                      vel: CGVector(dx: s * 60, dy: 25), life: 0.45)
            }
        }
        go(.landing)
    }

    private func landing() {
        snap()
        let amp = min(0.32, 0.08 + landingImpact / 9000)
        let k = CGFloat(exp(-t * 7) * cos(t * 20))
        sy = 1 - amp * k
        sx = 1 + amp * 0.6 * k
        frameKey = t < 0.35 ? "stand.surprised.0" : "stand.normal.0"
        guard t > 0.6 else { return }
        sx = 1; sy = 1
        if !pendingTalk.isEmpty {
            // reminders and the letter's lines come first, even after a hard landing
            dizzyAfterLanding = false
            greetAfterLanding = false
            let lines = pendingTalk
            pendingTalk.removeAll()
            startTalk(lines, then: .idle)
        } else if dizzyAfterLanding {
            dizzyAfterLanding = false
            if rng.chance(0.7) { say("dizzy") }
            startDizzy()
        } else if greetAfterLanding {
            greetAfterLanding = false
            startTalk([(pick("hello") ?? "Hi!", .wave)], then: .idle)
        } else {
            if landingImpact > 1400 && rng.chance(0.6) { say("drop") }
            toIdle(rng.range(2, 4))
        }
    }

    private func startDizzy() {
        sx = 1; sy = 1
        go(.dizzy)
    }

    private func dizzy() {
        snap()
        frameKey = "dizzy.\(Int(t * 6) % 4)"
        rotation = 0.07 * CGFloat(sin(t * 5))
        if t > 3.4 { toIdle(rng.range(2, 4)) }
    }

    private func startTalk(_ lines: [(String, TalkPose)], then next: PetState) {
        talkQueue = lines
        afterTalk = next
        bubble = nil
        rotation = 0; sx = 1; sy = 1
        go(.talking)
        nextLine()
    }

    private func nextLine() {
        guard !talkQueue.isEmpty else {
            if afterTalk == .idle { toIdle(rng.range(2, 4)) } else { go(afterTalk) }
            return
        }
        let (text, pose) = talkQueue.removeFirst()
        talkPose = pose
        let life = pose == .alert ? 12 : min(6, max(3, 2.2 + 0.07 * Double(text.count)))
        bubble = Bubble(text: text, life: life)
        t = 0
    }

    private func talking() {
        snap()
        switch talkPose {
        case .wave: frameKey = t < 1.6 ? "wave.\(Int(t * 3) % 2)" : "stand.\(eyes).\(breath)"
        case .waveShy: frameKey = t < 1.6 ? "wave.shy.\(Int(t * 3) % 2)" : "shy.\(breath)"
        case .love: frameKey = "love.\(breath)"
        case .shy: frameKey = "shy.\(breath)"
        case .alert:
            frameKey = "wave.\(Int(t * 3) % 2)"
            if clock > nextSpark {
                spawn("bang", at: headPoint + CGVector(dx: 26 * scale, dy: 6 * scale), vel: CGVector(dx: 0, dy: 18), life: 0.9)
                nextSpark = clock + 1.2
            }
        }
        if (talkPose == .love || talkPose == .waveShy) && clock > nextSpark {
            let h = headPoint
            spawn("heart", at: CGPoint(x: h.x + CGFloat(rng.range(-26, 26)) * scale, y: h.y - 6 * scale),
                  vel: CGVector(dx: rng.range(-10, 10), dy: 28), life: 1.4, wobble: 1)
            nextSpark = clock + 0.55
        }
        if bubble == nil { nextLine() }
    }

    // MARK: - desk

    /// Pull up the desk where he stands and get to work.
    func startWork() {
        guard !isBusy else { return }
        let b = screenBounds(pivot)
        talkQueue.removeAll()
        sx = 1; sy = 1; rotation = 0
        pivot.x = min(max(pivot.x, b.minX + 80 * scale), b.maxX - 90 * scale)
        // sit and think it through first, then write for a long stretch
        setDeskPose("think", for: rng.range(4, 7))
        nextCheer = clock + rng.range(cheerEvery.lowerBound, cheerEvery.upperBound)
        workUntil = clock + rng.range(workSession.lowerBound, workSession.upperBound)
        nodOffAt = clock + rng.range(nodOffAfter.lowerBound, nodOffAfter.upperBound)
        go(.working)
        frameKey = "desk.think"
        poof()
    }

    func setDeskPose(_ pose: String, for seconds: Double) {
        deskPose = pose
        poseUntil = clock + seconds
    }

    private func poof() {
        let f = feet
        for k in -2...2 {
            spawn("puff", at: CGPoint(x: f.x + CGFloat(k) * 28 * scale, y: f.y + 8 * scale),
                  vel: CGVector(dx: Double(k) * 30, dy: 30), life: 0.5)
        }
    }

    private func working() {
        snap()
        if deskPose == "type" && clock > nextCheer && !isNight() {
            cheer()
        } else if clock > poseUntil {
            if deskPose == "type" {
                deskBreather()
            } else {
                setDeskPose("type", for: rng.range(40, 120))
            }
        }
        if deskPose == "type" {
            // long runs of typing with a brief pause now and then to read what he wrote
            let typing = sin(t * 0.7) > -0.92
            frameKey = typing && Int(t * 6) % 2 == 0 ? "desk.type2" : "desk.type1"
            if typing && clock > nextSpark {
                let screenTop = toScreen(CGPoint(x: frame.anchor.x + 40, y: 90))
                var code = Int(rng.range(0, Double(CodeSnippets.all.count)))
                if code == lastCode { code = (code + 1) % CodeSnippets.all.count }
                lastCode = code
                spawn("code#\(code)",
                      at: CGPoint(x: screenTop.x + CGFloat(rng.range(-6, 6)) * scale, y: screenTop.y),
                      vel: CGVector(dx: rng.range(4, 14), dy: rng.range(26, 36)), life: 2.2)
                nextSpark = clock + rng.range(0.9, 1.5)
            }
        } else {
            frameKey = "desk.\(deskPose)"
        }
        if deskPose == "type" && isNight() && clock > nodOffAt {
            bubble = nil
            go(.deskSleeping)
        } else if deskPose == "type" && clock > workUntil && !isNight() {
            takeBreak()
        }
    }

    /// A short pause between long runs of typing: think, look up, sip a drink,
    /// stretch, grin at code that works or frown at a bug.
    private func deskBreather() {
        let next = rng.pick(["think", "think", "think", "lookup", "lookup", "happy", "angry", "drink", "drink", "stretch"]) ?? "think"
        switch next {
        case "think": setDeskPose(next, for: rng.range(3, 6))
        case "drink": setDeskPose(next, for: rng.range(3, 5))
        case "stretch": setDeskPose(next, for: 2.4)
        case "happy":
            setDeskPose(next, for: 2.2)
            spawn("sparkle", at: headPoint + CGVector(dx: 24 * scale, dy: 0), vel: CGVector(dx: 8, dy: 24), life: 0.9)
        case "angry":
            setDeskPose(next, for: 2.2)
            spawn("bang", at: headPoint + CGVector(dx: 24 * scale, dy: 4 * scale), vel: CGVector(dx: 0, dy: 20), life: 0.8)
        default: setDeskPose(next, for: rng.range(1.6, 2.6))
        }
    }

    /// Turn round to her, say something encouraging, send a few hearts, then back to work.
    private func cheer() {
        nextCheer = clock + rng.range(cheerEvery.lowerBound, cheerEvery.upperBound)
        setDeskPose("turn", for: 3.4)
        say("cheer")
        let h = headPoint
        for k in 0..<4 {
            spawn(k % 2 == 0 ? "heart" : "heart_s", at: CGPoint(x: h.x + CGFloat(rng.range(-26, 26)) * scale, y: h.y + CGFloat(k) * 6 * scale),
                  vel: CGVector(dx: rng.range(-12, 12), dy: rng.range(24, 36)), life: 1.6, wobble: 1)
        }
    }

    private func takeBreak() {
        breakUntil = clock + rng.range(breakLength.lowerBound, breakLength.upperBound)
        poof()
        let b = screenBounds(pivot)
        let m = 45 * scale
        var x = pivot.x + CGFloat(rng.range(160, 420)) * (rng.chance(0.5) ? 1 : -1)
        if x < b.minX + m || x > b.maxX - m { x = pivot.x - (x - pivot.x) }
        walkTarget = min(max(x, b.minX + m), b.maxX - m)
        facing = walkTarget >= pivot.x ? 1 : -1
        startTalk([(pick("break") ?? "Quick break", .wave)], then: .walking)
    }

    private func deskSleeping() {
        snap()
        frameKey = "desk.sleep"
        if clock > nextSpark {
            let big = Int(clock / 1.5) % 2 == 0
            spawn(big ? "z_l" : "z_s", at: headPoint + CGVector(dx: 22 * scale, dy: 6 * scale),
                  vel: CGVector(dx: 12 * scale, dy: 22 * scale), life: 2.6, wobble: 1)
            nextSpark = clock + 1.5
        }
    }

    private func wakeAtDesk() {
        lastInteraction = clock
        nodOffAt = clock + rng.range(nodOffAfter.lowerBound, nodOffAfter.upperBound)
        go(.working)
        setDeskPose("lookup", for: 2.4)
        say("wake")
    }

    // MARK: - helpers

    /// Put a standing pet straight onto the current floor (used after a Space switch).
    func settleOnFloor() {
        guard grabArt == nil, state != .held, state != .falling else { return }
        pivot.y = screenBounds(pivot).minY
        gliding = false
    }

    private func snap() {
        guard grabArt == nil else { return }
        let b = screenBounds(pivot)
        let m = 18 * scale
        let gap = b.minY - pivot.y
        gliding = abs(gap) > 0.5
        pivot.y = gliding ? pivot.y + gap * CGFloat(min(1, 9 * lastDt)) : b.minY
        pivot.x = min(max(pivot.x, b.minX + m), b.maxX - m)
    }

    private func keepOnScreen() {
        guard state != .held else { return }
        let b = screenBounds(feet)
        // fell off every screen (display unplugged, etc.): drop back in
        if feet.y < b.minY - 200 || feet.x < b.minX - 200 || feet.x > b.maxX + 200 {
            dropIn(atX: b.midX, y: b.midY)
        }
    }

    private func say(_ key: String) {
        guard let text = pick(key) else { return }
        bubble = Bubble(text: text, life: min(5, max(2.4, 1.8 + 0.06 * Double(text.count))))
    }

    private func pick(_ key: String) -> String? {
        var options = messages(key)
        if options.count > 1, let last = lastSaid[key] { options.removeAll { $0 == last } }
        let s = rng.pick(options)
        lastSaid[key] = s
        return s
    }

    private func spawn(_ sprite: String, at p: CGPoint, vel v: CGVector, life: Double, wobble: Double = 0) {
        if particles.count > 40 { particles.removeFirst() }
        particles.append(Particle(sprite: sprite, pos: p, vel: v, life: life, wobble: wobble))
    }

    private func updateParticles(_ dt: Double) {
        guard !particles.isEmpty else { return }
        for i in particles.indices {
            particles[i].age += dt
            var p = particles[i]
            let wob = p.wobble * cos(p.age * 4) * 12
            p.pos.x += (p.vel.dx + CGFloat(wob)) * CGFloat(dt)
            p.pos.y += p.vel.dy * CGFloat(dt)
            if p.sprite == "puff" { p.size = 1 + CGFloat(p.age) * 1.5 }
            particles[i] = p
        }
        particles.removeAll { $0.age >= $0.life }
    }
}

private func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
