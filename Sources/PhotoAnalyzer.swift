import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// A flat part measured from one photo taken from above, lying on a white A4 sheet.
/// All values are millimeters in the part's own frame: x along its long side, y up, minimum corner at 0.
struct PhotoPart {
    struct Hole {
        var outline: [SIMD2<Double>]
        var center: SIMD2<Double>
        /// Set when the hole is round.
        var diameter: Double?
        /// Width and length of the smallest rectangle around the hole (for slots and odd shapes).
        var width: Double
        var length: Double
    }

    var outline: [SIMD2<Double>]
    var corners: [SIMD2<Double>]
    var holes: [Hole]
    var size: SIMD2<Double>
    /// The straightened photo with what was detected drawn over it, to check the result.
    var check: UIImage?
}

enum PhotoDrawingError: LocalizedError {
    case badImage, noPaper, noPart

    var errorDescription: String? {
        switch self {
        case .badImage: return "לא הצלחתי לקרוא את התמונה."
        case .noPaper: return "לא מצאתי דף A4 בתמונה. צלם מלמעלה כשכל הדף בתמונה, על משטח כהה."
        case .noPart: return "לא מצאתי חלק על הדף. ודא שהחלק כהה מהדף ושהוא לא נוגע בשולי הדף."
        }
    }
}

enum PhotoAnalyzer {
    /// Pixels per millimeter of the straightened sheet.
    static let ppm = 5.0
    /// Strip around the sheet edge that is ignored (mm).
    static let margin = 4.0

    static func analyze(_ image: UIImage) throws -> PhotoPart {
        guard let cg = upright(image) else { throw PhotoDrawingError.badImage }

        // 1. Find the sheet.
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.25
        request.quadratureTolerance = 30
        request.minimumConfidence = 0.3
        request.maximumObservations = 6
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        func quadArea(_ r: VNRectangleObservation) -> CGFloat {
            let pts = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map(px)
            var a: CGFloat = 0
            for i in 0..<4 {
                let p = pts[i], q = pts[(i + 1) % 4]
                a += p.x * q.y - q.x * p.y
            }
            return abs(a) / 2
        }
        guard let sheet = (request.results ?? []).max(by: { quadArea($0) < quadArea($1) }) else {
            throw PhotoDrawingError.noPaper
        }

        // 2. Straighten it to exactly 297 x 210 mm (or 210 x 297) at `ppm` pixels per mm.
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: cg)
        filter.topLeft = px(sheet.topLeft)
        filter.topRight = px(sheet.topRight)
        filter.bottomLeft = px(sheet.bottomLeft)
        filter.bottomRight = px(sheet.bottomRight)
        guard let corrected = filter.outputImage, corrected.extent.width > 10, corrected.extent.height > 10 else {
            throw PhotoDrawingError.noPaper
        }
        let landscape = corrected.extent.width >= corrected.extent.height
        let sheetMM = landscape ? SIMD2(297.0, 210.0) : SIMD2(210.0, 297.0)
        let w = Int(sheetMM.x * ppm), h = Int(sheetMM.y * ppm)
        let fitted = corrected
            .transformed(by: CGAffineTransform(translationX: -corrected.extent.minX, y: -corrected.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / corrected.extent.width,
                                               y: CGFloat(h) / corrected.extent.height))
        let context = CIContext()
        guard let straight = context.createCGImage(fitted, from: CGRect(x: 0, y: 0, width: w, height: h)) else {
            throw PhotoDrawingError.badImage
        }

        // 3. Gray pixels, row 0 at the top.
        var gray = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(straight, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw PhotoDrawingError.badImage }

        // 4. Dark pixels = part. Threshold by Otsu inside the sheet margin.
        let m = Int(margin * ppm)
        var hist = [Int](repeating: 0, count: 256)
        for y in m..<(h - m) { for x in m..<(w - m) { hist[Int(gray[y * w + x])] += 1 } }
        let threshold = otsu(hist)
        var dark = [Bool](repeating: false, count: w * h)
        for y in m..<(h - m) { for x in m..<(w - m) where Int(gray[y * w + x]) < threshold { dark[y * w + x] = true } }

        // 5. The part is the largest dark region.
        let (labels, areas) = label(dark, w: w, h: h)
        guard let partLabel = areas.indices.max(by: { areas[$0] < areas[$1] }),
              Double(areas[partLabel]) > 25 * ppm * ppm else { throw PhotoDrawingError.noPart }
        let part = labels.map { $0 == partLabel }

        // 6. Holes: light regions enclosed by the part.
        let outside = floodOutside(part, w: w, h: h)
        let enclosed = (0..<(w * h)).map { !part[$0] && !outside[$0] }
        let (holeLabels, holeAreas) = label(enclosed, w: w, h: h)

        // Pixel (x, y-down) -> sheet millimeters (y up).
        func mm(_ x: Int, _ y: Int) -> SIMD2<Double> { SIMD2((Double(x) + 0.5) / ppm, (Double(h - y) - 0.5) / ppm) }

        let outlinePx = trace(part, w: w, h: h)
        var outline = simplify(outlinePx.map { mm($0.0, $0.1) }, tolerance: 0.3)
        var holeShapes: [(outline: [SIMD2<Double>], pixels: [SIMD2<Double>], area: Double)] = []
        for (i, area) in holeAreas.enumerated() where Double(area) >= 1.5 * ppm * ppm {
            let mask = holeLabels.map { $0 == i }
            let shape = simplify(trace(mask, w: w, h: h).map { mm($0.0, $0.1) }, tolerance: 0.2)
            var pixels: [SIMD2<Double>] = []
            pixels.reserveCapacity(area)
            for idx in 0..<(w * h) where mask[idx] { pixels.append(mm(idx % w, idx / w)) }
            holeShapes.append((outline: shape, pixels: pixels, area: Double(area) / (ppm * ppm)))
        }

        // 7. Turn so the part's smallest bounding rectangle is axis-aligned, long side along x.
        let angle = bestAngle(outline)
        func rot(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(p.x * cos(angle) + p.y * sin(angle), -p.x * sin(angle) + p.y * cos(angle))
        }
        outline = outline.map(rot)
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for p in outline { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var swap = false
        if hi.y - lo.y > hi.x - lo.x { swap = true }
        func toPart(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let q = rot(p) - lo
            return swap ? SIMD2(hi.y - lo.y - q.y, q.x) : q
        }
        let finalOutline = outline.map { p -> SIMD2<Double> in
            let q = p - lo
            return swap ? SIMD2(hi.y - lo.y - q.y, q.x) : q
        }
        let pixelHalf = 0.5 / ppm
        let size = swap ? SIMD2(hi.y - lo.y, hi.x - lo.x) + 2 * pixelHalf : hi - lo + 2 * pixelHalf

        var holes: [PhotoPart.Hole] = []
        for shape in holeShapes {
            let pts = shape.pixels.map(toPart)
            var c = SIMD2<Double>.zero
            for p in pts { c += p }
            c /= Double(pts.count)
            let a = bestAngle(pts)
            var hlo = SIMD2<Double>(repeating: .infinity), hhi = SIMD2<Double>(repeating: -.infinity)
            for p in pts {
                let q = SIMD2(p.x * cos(a) + p.y * sin(a), -p.x * sin(a) + p.y * cos(a))
                hlo = simd_min(hlo, q); hhi = simd_max(hhi, q)
            }
            let ext = hhi - hlo + 2 * pixelHalf
            let width = min(ext.x, ext.y), length = max(ext.x, ext.y)
            let circleArea = Double.pi / 4 * width * length
            let round = (length - width) / length < 0.12 && abs(shape.area / circleArea - 1) < 0.12
            holes.append(PhotoPart.Hole(outline: shape.outline.map(toPart), center: c,
                                        diameter: round ? 2 * sqrt(shape.area / .pi) : nil,
                                        width: width, length: length))
        }
        // Order holes left to right, then bottom to top.
        holes.sort { abs($0.center.x - $1.center.x) > 1 ? $0.center.x < $1.center.x : $0.center.y < $1.center.y }

        let corners = cornerPoints(simplify(finalOutline, tolerance: 1.0))
        let check = checkImage(straight, outline: outlinePx, holeLabels: holeLabels, w: w, h: h)
        return PhotoPart(outline: finalOutline, corners: corners, holes: holes, size: size, check: check)
    }

    // MARK: - Image helpers

    static func upright(_ image: UIImage, maxSide: CGFloat = 3000) -> CGImage? {
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * s).rounded(), height: (image.size.height * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    static func otsu(_ hist: [Int]) -> Int {
        let total = hist.reduce(0, +)
        guard total > 0 else { return 128 }
        var sum = 0.0
        for (i, n) in hist.enumerated() { sum += Double(i * n) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t + 1 }
        }
        return threshold
    }

    /// 4-connected regions of `mask`. Returns a label per pixel (-1 = not in mask) and each region's size.
    static func label(_ mask: [Bool], w: Int, h: Int) -> ([Int], [Int]) {
        var labels = [Int](repeating: -1, count: w * h)
        var areas: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && labels[start] < 0 {
            let id = areas.count
            var count = 0
            labels[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                if x > 0, mask[i - 1], labels[i - 1] < 0 { labels[i - 1] = id; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], labels[i + 1] < 0 { labels[i + 1] = id; stack.append(i + 1) }
                if y > 0, mask[i - w], labels[i - w] < 0 { labels[i - w] = id; stack.append(i - w) }
                if y < h - 1, mask[i + w], labels[i + w] < 0 { labels[i + w] = id; stack.append(i + w) }
            }
            areas.append(count)
        }
        return (labels, areas)
    }

    /// Pixels not in `part` that connect (8-way) to the image border.
    static func floodOutside(_ part: [Bool], w: Int, h: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func push(_ i: Int) { if !part[i] && !out[i] { out[i] = true; stack.append(i) } }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny >= 0, ny < h { push(ny * w + nx) }
                }
            }
        }
        return out
    }

    /// Moore-neighbour boundary trace of the region's outer edge, as pixel coordinates (y down).
    static func trace(_ mask: [Bool], w: Int, h: Int) -> [(Int, Int)] {
        guard let first = mask.firstIndex(of: true) else { return [] }
        let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h && mask[y * w + x] }
        let start = (first % w, first / w)
        var p = start
        var back = 4          // came from the west, which is outside
        var contour = [p]
        let limit = 4 * (w + h) * 8
        while contour.count < limit {
            var moved = false
            for k in 1...8 {
                let d = (back + k) % 8
                let q = (p.0 + dirs[d].0, p.1 + dirs[d].1)
                if inside(q.0, q.1) {
                    let prev = (back + k - 1) % 8
                    let c = (p.0 + dirs[prev].0, p.1 + dirs[prev].1)
                    let delta = (c.0 - q.0, c.1 - q.1)
                    back = dirs.firstIndex { $0 == delta } ?? 4
                    p = q
                    moved = true
                    break
                }
            }
            if !moved || (p == start && contour.count > 2) { break }
            contour.append(p)
        }
        return contour
    }

    /// Douglas-Peucker on a closed polyline.
    static func simplify(_ pts: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard pts.count > 4 else { return pts }
        // Split the loop at the point farthest from the first one and simplify both halves.
        let far = pts.indices.max { simd_distance(pts[$0], pts[0]) < simd_distance(pts[$1], pts[0]) } ?? pts.count / 2
        guard far > 0 else { return pts }
        var out: [SIMD2<Double>] = []
        simplifyOpen(Array(pts[0...far]), tolerance: tolerance, into: &out)
        simplifyOpen(Array(pts[far...]) + [pts[0]], tolerance: tolerance, into: &out)
        return out
    }

    private static func simplifyOpen(_ pts: [SIMD2<Double>], tolerance: Double, into out: inout [SIMD2<Double>]) {
        func dp(_ a: Int, _ b: Int) {
            let pa = pts[a], pb = pts[b]
            var maxD = 0.0, idx = -1
            if b - a > 1 {
                let e = pb - pa
                let len = simd_length(e)
                for i in (a + 1)..<b {
                    let v = pts[i] - pa
                    let d = len > 0 ? abs(e.x * v.y - e.y * v.x) / len : simd_length(v)
                    if d > maxD { maxD = d; idx = i }
                }
            }
            if maxD > tolerance && idx > 0 { dp(a, idx); dp(idx, b) } else { out.append(pa) }
        }
        if pts.count >= 2 { dp(0, pts.count - 1) }
    }

    /// Angle (radians) that turns the points so their bounding rectangle is smallest.
    static func bestAngle(_ pts: [SIMD2<Double>]) -> Double {
        guard pts.count >= 3 else { return 0 }
        let step = max(1, pts.count / 3000)
        let sample = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
        var best = 0.0, bestArea = Double.infinity
        for i in 0..<360 {
            let a = Double(i) * 0.25 * .pi / 180
            let c = cos(a), s = sin(a)
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for p in sample {
                let u = p.x * c + p.y * s, v = -p.x * s + p.y * c
                minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
            }
            let area = (maxU - minU) * (maxV - minV)
            if area < bestArea - 1e-9 { bestArea = area; best = a }
        }
        return best
    }

    /// Outline vertices where the direction turns by more than 25 degrees.
    static func cornerPoints(_ poly: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard poly.count >= 3 else { return poly }
        var out: [SIMD2<Double>] = []
        for i in 0..<poly.count {
            let a = poly[(i + poly.count - 1) % poly.count], b = poly[i], c = poly[(i + 1) % poly.count]
            let u = b - a, v = c - b
            let lu = simd_length(u), lv = simd_length(v)
            guard lu > 2, lv > 2 else { continue }
            let cosT = simd_dot(u, v) / (lu * lv)
            if cosT < cos(25 * Double.pi / 180) { out.append(b) }
        }
        return out
    }

    static func checkImage(_ straight: CGImage, outline: [(Int, Int)], holeLabels: [Int], w: Int, h: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: w, height: h)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: straight).draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.systemRed.cgColor)
            cg.setLineWidth(3)
            if let f = outline.first {
                cg.move(to: CGPoint(x: f.0, y: f.1))
                for p in outline.dropFirst() { cg.addLine(to: CGPoint(x: p.0, y: p.1)) }
                cg.closePath()
                cg.strokePath()
            }
            cg.setFillColor(UIColor.systemGreen.withAlphaComponent(0.6).cgColor)
            for i in 0..<(w * h) where holeLabels[i] >= 0 {
                cg.fill(CGRect(x: i % w, y: i / w, width: 1, height: 1))
            }
        }
    }
}
