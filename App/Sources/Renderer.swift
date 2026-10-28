import AppKit
import CoreText

/// Draws a PetEngine into any CGContext whose user space is screen points (y up) offset by `origin`.
/// The character is drawn smoothly; speech bubbles and effects are pixel art drawn with
/// nearest-neighbour scaling, all at the same pixel size. Code chips are drawn smoothly.
final class Renderer {
    let effects: [String: Frame]
    private let ts: CGFloat
    private let font: NSFont
    private var bubbleCache: (text: String, image: CGImage)?
    private var codeCache: [Int: CGImage] = [:]

    private static let ink: (UInt8, UInt8, UInt8) = (46, 30, 50)
    private static let paper: (UInt8, UInt8, UInt8) = (255, 252, 250)

    /// `textScale` enlarges speech bubbles (used for the demo videos).
    init(effects: [String: Frame], textScale: CGFloat = 1) {
        self.effects = effects
        ts = textScale
        font = NSFont.systemFont(ofSize: 26, weight: .bold)
    }

    /// `pixel` is the device pixel size in points (0.5 on Retina).
    func draw(_ e: PetEngine, in ctx: CGContext, origin: CGPoint, screen: CGRect, pixel: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let px = pixelSize(e, device: pixel)
        drawStars(e, ctx, px: px, front: false)
        ctx.interpolationQuality = .high
        drawPet(e, ctx, pixel: pixel)
        drawStars(e, ctx, px: px, front: true)
        drawParticles(e, ctx, px: px, screen: screen)
        if let b = e.bubble { drawBubble(b, e, ctx, screen, px: px) }
        ctx.restoreGState()
    }

    /// Size in points of one pixel of the effects and bubbles: a whole number of device pixels.
    private func pixelSize(_ e: PetEngine, device: CGFloat) -> CGFloat {
        let want = e.scale * 3 * ts
        return max(device, (want / device).rounded() * device)
    }

    private func snap(_ v: CGFloat, _ px: CGFloat) -> CGFloat { (v / px).rounded() * px }

    private func drawPet(_ e: PetEngine, _ ctx: CGContext, pixel: CGFloat) {
        let f = e.frame, p = e.pivotArt
        ctx.saveGState()
        if e.rotation == 0 && e.sx == 1 && e.sy == 1 {
            let x0 = snap(e.pivot.x - p.x * e.scale * e.drawFacing, pixel)
            let y0 = snap(e.pivot.y - (CGFloat(f.height) - p.y) * e.scale, pixel)
            ctx.translateBy(x: x0, y: y0)
            ctx.scaleBy(x: e.scale * e.drawFacing, y: e.scale)
            ctx.draw(f.image, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
        } else {
            ctx.translateBy(x: e.pivot.x, y: e.pivot.y)
            ctx.rotate(by: e.rotation)
            ctx.scaleBy(x: e.scale * e.drawFacing * e.sx, y: e.scale * e.sy)
            ctx.draw(f.image, in: CGRect(x: -p.x, y: -(CGFloat(f.height) - p.y), width: CGFloat(f.width), height: CGFloat(f.height)))
        }
        ctx.restoreGState()
    }

    private func sprite(_ name: String, at p: CGPoint, px: CGFloat, alpha: CGFloat, _ ctx: CGContext) {
        guard let fr = effects[name] else { return }
        let w = CGFloat(fr.width) * px, h = CGFloat(fr.height) * px
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setAlpha(alpha)
        ctx.draw(fr.image, in: CGRect(x: snap(p.x - w / 2, px), y: snap(p.y - h / 2, px), width: w, height: h))
        ctx.restoreGState()
    }

    private func drawStars(_ e: PetEngine, _ ctx: CGContext, px: CGFloat, front: Bool) {
        guard let ph = e.starsPhase else { return }
        let h = e.headPoint
        for k in 0..<3 {
            let a = ph * 4 + Double(k) * 2 * .pi / 3
            guard (sin(a) < 0) == front else { continue }
            let ox = CGFloat(cos(a)) * 30 * e.scale
            let oy = CGFloat(sin(a)) * 8 * e.scale + 4 * e.scale
            sprite("star", at: CGPoint(x: h.x + ox, y: h.y + oy), px: px, alpha: 1, ctx)
        }
    }

    private func drawParticles(_ e: PetEngine, _ ctx: CGContext, px: CGFloat, screen: CGRect) {
        for p in e.particles {
            let a = min(1, p.age / 0.12) * min(1, (p.life - p.age) / 0.4)
            if p.sprite.hasPrefix("code#"), let i = Int(p.sprite.dropFirst(5)) {
                drawCode(i, at: p.pos, age: p.age, alpha: CGFloat(max(0, a)), screen: screen, e, ctx)
                continue
            }
            let size = max(px, (px * p.size / px).rounded() * px)
            sprite(p.sprite, at: p.pos, px: size, alpha: CGFloat(max(0, a)), ctx)
        }
    }

    // MARK: - code chips

    /// A line of code floating up from the laptop, drawn at the character's own resolution.
    /// `p` is the chip's left end, so it grows away from his face.
    private func drawCode(_ i: Int, at p: CGPoint, age: Double, alpha: CGFloat, screen: CGRect, _ e: PetEngine, _ ctx: CGContext) {
        guard let img = codeImage(i) else { return }
        let px = e.scale * ts
        let pop = CGFloat(age < 0.2 ? 0.7 + 0.3 * (age / 0.2) : 1)
        let w = CGFloat(img.width) * px * pop, h = CGFloat(img.height) * px * pop
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.setAlpha(alpha)
        ctx.draw(img, in: CGRect(x: min(p.x, screen.maxX - w - 6), y: p.y - h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    private func codeImage(_ i: Int) -> CGImage? {
        if let c = codeCache[i] { return c }
        let parts = CodeSnippets.all[i % CodeSnippets.all.count]
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
        let line = NSMutableAttributedString()
        for (text, rgb) in parts {
            line.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                                          blue: CGFloat(rgb & 0xFF) / 255, alpha: 1),
            ]))
        }
        let ct = CTLineCreateWithAttributedString(line)
        let tb = CTLineGetBoundsWithOptions(ct, .useOpticalBounds)
        let padX: CGFloat = 10, padY: CGFloat = 6
        let w = Int(ceil(tb.width + 2 * padX)), h = Int(ceil(font.ascender - font.descender + 2 * padY))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGRect(x: 1, y: 1, width: CGFloat(w) - 2, height: CGFloat(h) - 2)
        let path = CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.16, alpha: 0.9))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: padX - tb.minX, y: padY - font.descender)
        CTLineDraw(ct, ctx)
        let img = ctx.makeImage()
        codeCache[i] = img
        return img
    }

    // MARK: - pixel speech bubble

    private func drawBubble(_ b: Bubble, _ e: PetEngine, _ ctx: CGContext, _ screen: CGRect, px _: CGFloat) {
        guard let img = bubbleImage(b.text) else { return }
        // one bubble pixel = one pixel of the character, so text is as sharp as the pet
        let px = e.scale * ts
        let bw = CGFloat(img.width) * px, bh = CGFloat(img.height) * px
        let head = e.headPoint
        let x = snap(min(max(head.x - bw / 2, screen.minX + 6), screen.maxX - bw - 6), px)
        let y = snap(min(head.y + 4 * e.scale, screen.maxY - bh - 6), px)
        let pop = b.age < 0.18 ? 0.6 + 0.4 * (b.age / 0.18) : 1
        let alpha = min(1, (b.life - b.age) / 0.3)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.setAlpha(CGFloat(max(0, alpha)))
        let cx = x + bw / 2
        ctx.translateBy(x: cx, y: y)
        ctx.scaleBy(x: CGFloat(pop), y: CGFloat(pop))
        ctx.translateBy(x: -cx, y: -y)
        ctx.draw(img, in: CGRect(x: x, y: y, width: bw, height: bh))
        ctx.restoreGState()
    }

    /// Builds the bubble at the character's own resolution: a box with stepped corners and a
    /// tail (in 2x2 blocks), with smooth text drawn on top.
    private func bubbleImage(_ text: String) -> CGImage? {
        if let c = bubbleCache, c.text == text { return c.image }
        let ink = Renderer.ink, paper = Renderer.paper
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: para,
            .foregroundColor: NSColor(srgbRed: CGFloat(ink.0) / 255, green: CGFloat(ink.1) / 255, blue: CGFloat(ink.2) / 255, alpha: 1),
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: 230, height: 400), nil)
        let blk = 2  // block size of the frame
        let tw = Int(ceil(fit.width)) + 2, th = Int(ceil(fit.height)) + 2
        let gw = (tw + 1) / blk + 8, gBoxH = (th + 1) / blk + 6, tail = 4
        let w = gw * blk, boxH = gBoxH * blk, h = boxH + tail * blk
        var buf = [UInt8](repeating: 0, count: w * h * 4)

        func put(_ gx: Int, _ gy: Int, _ c: (UInt8, UInt8, UInt8)) {  // one block, y from the top
            for y in gy * blk..<(gy + 1) * blk {
                for x in gx * blk..<(gx + 1) * blk where x >= 0 && y >= 0 && x < w && y < h {
                    let i = (y * w + x) * 4
                    buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2; buf[i + 3] = 255
                }
            }
        }
        // box with stepped corners
        for y in 0..<gBoxH {
            for x in 0..<gw {
                let cx = min(x, gw - 1 - x), cy = min(y, gBoxH - 1 - y)
                if cx + cy < 2 { continue }
                let edge = cx == 0 || cy == 0 || cx + cy == 2
                put(x, y, edge ? ink : paper)
            }
        }
        // tail pointing down from the middle
        let mid = gw / 2
        for j in 0..<tail {
            let half = tail - 1 - j
            for x in (mid - half)...(mid + half) {
                put(x, gBoxH - 1 + j, (x == mid - half || x == mid + half) ? ink : paper)
            }
        }
        put(mid, gBoxH - 2 + tail, ink)

        // smooth text drawn straight onto the box
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let box = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(box, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.textMatrix = .identity
        let tx = (w - tw) / 2, ty = tail * blk + (boxH - th) / 2
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: tx, y: ty, width: tw, height: th), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let img = ctx.makeImage() else { return nil }
        bubbleCache = (text, img)
        return img
    }
}

/// Web and AI code that floats up while he types: (text, 0xRRGGBB) pieces, coloured like an editor.
enum CodeSnippets {
    private static let kw = 0xFF79C6, fn = 0x8BE9FD, str = 0xF1FA8C, tag = 0xFFB86C, txt = 0xF8F8F2, num = 0xBD93F9, ok = 0x50FA7B

    static let all: [[(String, Int)]] = [
        [("<", txt), ("div", tag), (" className", ok), ("=", txt), ("\"app\"", str), (">", txt)],
        [("const", kw), (" [user] = ", txt), ("useState", fn), ("()", txt)],
        [("await", kw), (" ", txt), ("fetch", fn), ("(", txt), ("'/api/chat'", str), (")", txt)],
        [("npm", fn), (" run dev", txt)],
        [("export default", kw), (" ", txt), ("App", fn)],
        [("<", txt), ("Button", tag), (" onClick", ok), ("={send}", txt), (" />", txt)],
        [("import", kw), (" torch", txt)],
        [("model", txt), (".", txt), ("fit", fn), ("(X, y, epochs=", txt), ("10", num), (")", txt)],
        [("const", kw), (" reply = ", txt), ("await", kw), (" llm.", txt), ("chat", fn), ("(prompt)", txt)],
        [("prompt", txt), (" = ", txt), ("\"You are a helpful AI\"", str)],
        [("loss", txt), (": ", txt), ("0.0231", num), (" ✓", ok)],
        [("git", fn), (" commit -m ", txt), ("\"ship it\"", str)],
        [("display", ok), (": ", txt), ("flex", str), (";", txt)],
        [("def", kw), (" ", txt), ("train", fn), ("(data):", txt)],
        [("tokens", txt), (" += ", kw), ("1", num)],
        [("✓", ok), (" build passed", txt)],
    ]
}
