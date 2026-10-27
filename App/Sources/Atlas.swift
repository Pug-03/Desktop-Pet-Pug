import CoreGraphics
import Foundation
import ImageIO

/// One sprite frame cut out of an atlas. Art coordinates are pixels, origin top-left, y down.
struct Frame {
    let image: CGImage
    let width: Int
    let height: Int
    let anchor: CGPoint  // feet, bottom-center
    let head: CGPoint    // top of the head
    let face: CGPoint    // middle of the face
    let alpha: [UInt8]

    func opaque(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return alpha[y * width + x] > 0
    }
}

enum Atlas {
    static func load(png: URL, json: URL) -> [String: Frame]? {
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = try? Data(contentsOf: json),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return nil }

        let w = atlas.width, h = atlas.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        // decode once into memory; drawing a lazily-decoded PNG would re-inflate it every frame
        let decoded = rgba.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(atlas, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        guard let sheet = decoded else { return nil }

        func point(_ v: Any?, _ fallback: CGPoint) -> CGPoint {
            guard let a = v as? [NSNumber], a.count == 2 else { return fallback }
            return CGPoint(x: a[0].doubleValue, y: a[1].doubleValue)
        }

        var frames: [String: Frame] = [:]
        for (name, m) in meta {
            guard let r = m["rect"] as? [Int], r.count == 4,
                  let img = sheet.cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
            else { continue }
            var a = [UInt8](repeating: 0, count: r[2] * r[3])
            for y in 0..<r[3] {
                for x in 0..<r[2] {
                    a[y * r[2] + x] = rgba[((r[1] + y) * w + r[0] + x) * 4 + 3]
                }
            }
            let anchor = point(m["anchor"], CGPoint(x: r[2] / 2, y: r[3]))
            frames[name] = Frame(image: img, width: r[2], height: r[3], anchor: anchor,
                                 head: point(m["head"], CGPoint(x: anchor.x, y: 0)),
                                 face: point(m["face"], CGPoint(x: anchor.x, y: CGFloat(r[3]) * 0.25)),
                                 alpha: a)
        }
        return frames
    }
}
