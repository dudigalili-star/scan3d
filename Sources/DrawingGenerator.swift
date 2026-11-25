import UIKit
import simd

/// Mesh prepared for drawing: cleaned, gravity-aligned, in millimeters with its minimum corner at 0.
/// Axes: x = width (longest horizontal side), y = depth, z = height (up).
struct DrawingModel {
    var points: [SIMD3<Double>]
    var triangles: [SIMD3<Int32>]
    var normals: [SIMD3<Double>]
    var size: SIMD3<Double>
}

enum DrawingGenerator {

    // MARK: - Preparation

    /// `scale` is the caliper correction factor. Object Capture models are Y-up and gravity-aligned.
    static func prepare(_ mesh: MeshData, scale: Double) -> DrawingModel? {
        let k = 1000 * scale
        let raw = mesh.positions.map { SIMD3<Double>(Double($0.x) * k, Double($0.y) * k, Double($0.z) * k) }
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity(mesh.indices.count / 3)
        var i = 0
        while i + 2 < mesh.indices.count {
            tris.append(SIMD3(Int32(mesh.indices[i]), Int32(mesh.indices[i + 1]), Int32(mesh.indices[i + 2])))
            i += 3
        }
        guard !raw.isEmpty, !tris.isEmpty else { return nil }

        // 1. Drop leftovers of the table: geometry in the bottom 3 mm that lies outside
        //    the footprint of the body above it.
        let y0 = raw.map(\.y).min() ?? 0
        let upper = raw.filter { $0.y > y0 + 5 }.map { SIMD2<Double>($0.x, $0.z) }
        if upper.count >= 3 {
            let hull = convexHull(upper)
            let keep = raw.map { $0.y > y0 + 3 || insideConvex(SIMD2($0.x, $0.z), hull, margin: 1.0) }
            tris = tris.filter { keep[Int($0.x)] && keep[Int($0.y)] && keep[Int($0.z)] }
        }

        // 2. Keep only the large connected pieces (removes floating fragments).
        tris = largeComponents(tris, vertexCount: raw.count, minShare: 0.02)
        guard !tris.isEmpty else { return nil }

        // 3. Reindex to the vertices still in use.
        var remap = [Int32](repeating: -1, count: raw.count)
        var pts: [SIMD3<Double>] = []
        for t in tris {
            for v in [t.x, t.y, t.z] where remap[Int(v)] < 0 {
                remap[Int(v)] = Int32(pts.count)
                pts.append(raw[Int(v)])
            }
        }
        tris = tris.map { SIMD3(remap[Int($0.x)], remap[Int($0.y)], remap[Int($0.z)]) }

        // 4. Turn about the vertical axis so the footprint's bounding rectangle is smallest.
        var center = SIMD2<Double>.zero
        for p in pts { center += SIMD2(p.x, p.z) }
        center /= Double(pts.count)
        let step = max(1, pts.count / 5000)
        let sample = stride(from: 0, to: pts.count, by: step).map { SIMD2(pts[$0].x, pts[$0].z) - center }
        var bestAngle = 0.0, bestArea = Double.infinity
        for tenth in stride(from: 0, to: 900, by: 5) {
            let a = Double(tenth) / 10 * .pi / 180
            let c = cos(a), s = sin(a)
            var us: [Double] = [], vs: [Double] = []
            us.reserveCapacity(sample.count); vs.reserveCapacity(sample.count)
            for q in sample {
                us.append(q.x * c + q.y * s)
                vs.append(-q.x * s + q.y * c)
            }
            let area = trimmedSpan(&us) * trimmedSpan(&vs)
            if area < bestArea { bestArea = area; bestAngle = a }
        }
        let c = cos(bestAngle), s = sin(bestAngle)
        var local = pts.map { p -> SIMD3<Double> in
            let q = SIMD2(p.x, p.z) - center
            return SIMD3(q.x * c + q.y * s, -q.x * s + q.y * c, p.y)
        }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in local { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if hi.y - lo.y > hi.x - lo.x {
            local = local.map { SIMD3($0.y, $0.x, $0.z) }
            lo = SIMD3(lo.y, lo.x, lo.z); hi = SIMD3(hi.y, hi.x, hi.z)
        }
        local = local.map { $0 - lo }

        let normals = tris.map { t -> SIMD3<Double> in
            let a = local[Int(t.x)], b = local[Int(t.y)], cc = local[Int(t.z)]
            let n = simd_cross(b - a, cc - a)
            let len = simd_length(n)
            return len > 0 ? n / len : .zero
        }
        return DrawingModel(points: local, triangles: tris, normals: normals, size: hi - lo)
    }

    private static func trimmedSpan(_ values: inout [Double]) -> Double {
        values.sort()
        let n = values.count
        return values[(n - 1) * 99 / 100] - values[(n - 1) / 100]
    }

    static func convexHull(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let pts = input.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Hull is counter-clockwise. True when the point is inside, or within `margin` outside it.
    static func insideConvex(_ p: SIMD2<Double>, _ hull: [SIMD2<Double>], margin: Double) -> Bool {
        guard hull.count >= 3 else { return true }
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let e = b - a
            let len = simd_length(e)
            guard len > 0 else { continue }
            let inward = SIMD2(-e.y, e.x) / len
            if simd_dot(p - a, inward) < -margin { return false }
        }
        return true
    }

    private static func largeComponents(_ tris: [SIMD3<Int32>], vertexCount: Int, minShare: Double) -> [SIMD3<Int32>] {
        var parent = Array(0..<vertexCount)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for t in tris { union(Int(t.x), Int(t.y)); union(Int(t.x), Int(t.z)) }
        var counts: [Int: Int] = [:]
        let roots = tris.map { find(Int($0.x)) }
        for r in roots { counts[r, default: 0] += 1 }
        let minCount = Int(Double(tris.count) * minShare)
        return zip(tris, roots).filter { counts[$0.1, default: 0] >= minCount }.map { $0.0 }
    }

    // MARK: - Views and edges

    struct View {
        let toward: SIMD3<Double>                 // unit vector pointing at the viewer
        let project: (SIMD3<Double>) -> SIMD2<Double>
    }

    static let front = View(toward: SIMD3(0, -1, 0)) { SIMD2($0.x, $0.z) }
    static let top   = View(toward: SIMD3(0, 0, 1))  { SIMD2($0.x, $0.y) }
    static let right = View(toward: SIMD3(1, 0, 0))  { SIMD2($0.y, $0.z) }

    private struct EdgeFaces { var f0: Int; var f1: Int = -1; var count = 1 }

    private static func edgeTable(_ m: DrawingModel) -> [(UInt64, EdgeFaces)] {
        var table: [UInt64: EdgeFaces] = [:]
        table.reserveCapacity(m.triangles.count * 2)
        for (fi, t) in m.triangles.enumerated() {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                let key = (UInt64(UInt32(min(a, b))) << 32) | UInt64(UInt32(max(a, b)))
                if var e = table[key] {
                    if e.count == 1 { e.f1 = fi }
                    e.count += 1
                    table[key] = e
                } else {
                    table[key] = EdgeFaces(f0: fi)
                }
            }
        }
        return Array(table)
    }

    /// Outline (silhouette and open borders) plus sharp edges facing the viewer.
    static func visibleEdges(_ m: DrawingModel, view: View, sharpDegrees: Double = 40) -> [(Int, Int)] {
        let cosSharp = cos(sharpDegrees * .pi / 180)
        var out: [(Int, Int)] = []
        for (key, e) in edgeTable(m) {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            if e.count != 2 { out.append((a, b)); continue }
            let n0 = m.normals[e.f0], n1 = m.normals[e.f1]
            let d0 = simd_dot(n0, view.toward), d1 = simd_dot(n1, view.toward)
            if (d0 > 0) != (d1 > 0) {
                out.append((a, b))
            } else if simd_dot(n0, n1) < cosSharp && (d0 > 0 || d1 > 0) {
                out.append((a, b))
            }
        }
        return out
    }

    // MARK: - PDF

    private static let niceScales: [Double] = [10, 5, 4, 2, 1, 0.5, 0.4, 0.25, 0.2, 0.1, 0.05, 0.02, 0.01]
    private static let ptPerMM = 72.0 / 25.4

    static func scaleLabel(_ paperPerModel: Double) -> String {
        if paperPerModel >= 1 { return "\(Int(paperPerModel.rounded())):1" }
        return "1:\(Int((1 / paperPerModel).rounded()))"
    }

    static func mmText(_ v: Double) -> String { String(format: "%.1f", v) }

    /// A4 landscape: front view bottom-left, top view above it, right view beside it (third-angle).
    @discardableResult
    static func renderPDF(_ m: DrawingModel, title: String, date: Date, to url: URL) throws -> String {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)
        let area = CGRect(x: 30, y: 30, width: 782, height: 450)
        let pad: CGFloat = 46
        let L = m.size.x, W = m.size.y, H = m.size.z
        let fitX = (Double(area.width) - 3.5 * Double(pad)) / max(L + W, 1)
        let fitY = (Double(area.height) - 3.5 * Double(pad)) / max(H + W, 1)
        let fit = min(fitX, fitY) / ptPerMM
        let paper = niceScales.first { $0 <= fit } ?? niceScales.last!
        let s = CGFloat(paper * ptPerMM)

        let fx = area.minX + pad
        let baseY = area.maxY - pad
        let topBase = baseY - CGFloat(H) * s - pad * 1.5
        let rx = fx + CGFloat(L) * s + pad * 1.5

        let placements: [(View, CGPoint)] = [
            (front, CGPoint(x: fx, y: baseY)),
            (top, CGPoint(x: fx, y: topBase)),
            (right, CGPoint(x: rx, y: baseY))
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            let ctx = context.cgContext

            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(page.insetBy(dx: 15, dy: 15))

            for (view, origin) in placements {
                func pt(_ p: SIMD3<Double>) -> CGPoint {
                    let q = view.project(p)
                    return CGPoint(x: origin.x + CGFloat(q.x) * s, y: origin.y - CGFloat(q.y) * s)
                }
                let fill = CGMutablePath()
                for t in m.triangles {
                    fill.move(to: pt(m.points[Int(t.x)]))
                    fill.addLine(to: pt(m.points[Int(t.y)]))
                    fill.addLine(to: pt(m.points[Int(t.z)]))
                    fill.closeSubpath()
                }
                ctx.addPath(fill)
                ctx.setFillColor(UIColor(white: 0.9, alpha: 1).cgColor)
                ctx.fillPath(using: .winding)

                let lines = CGMutablePath()
                for (a, b) in visibleEdges(m, view: view) {
                    lines.move(to: pt(m.points[a]))
                    lines.addLine(to: pt(m.points[b]))
                }
                ctx.addPath(lines)
                ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.setLineWidth(0.35)
                ctx.strokePath()
            }

            // Overall dimensions
            let frontRight = fx + CGFloat(L) * s
            let frontTop = baseY - CGFloat(H) * s
            horizontalDimension(ctx, x1: fx, x2: frontRight, from: baseY, at: baseY + 22, text: mmText(L))
            verticalDimension(ctx, y1: frontTop, y2: baseY, from: fx, at: fx - 22, text: mmText(H))
            verticalDimension(ctx, y1: topBase - CGFloat(W) * s, y2: topBase, from: fx, at: fx - 22, text: mmText(W))

            label(ctx, "חזית", at: CGPoint(x: fx + CGFloat(L) * s / 2, y: baseY + 36), size: 9, centered: true)
            label(ctx, "מבט עליון", at: CGPoint(x: fx + CGFloat(L) * s / 2, y: topBase + 8), size: 9, centered: true)
            label(ctx, "מבט צד", at: CGPoint(x: rx + CGFloat(W) * s / 2, y: baseY + 8), size: 9, centered: true)

            // Title block
            let block = CGRect(x: 812 - 300, y: 492, width: 300, height: 88)
            ctx.setLineWidth(0.8)
            ctx.stroke(block)
            let df = DateFormatter()
            df.dateFormat = "dd.MM.yyyy"
            let rows = [
                title,
                "תאריך: \(df.string(from: date))    יחידות: מ\"מ    קנה מידה: \(scaleLabel(paper))",
                "מידות כלליות: \(mmText(L)) × \(mmText(W)) × \(mmText(H))",
                "מקור: סריקת LiDAR. מידות קריטיות יש לאמת בקליבר."
            ]
            for (i, row) in rows.enumerated() {
                let y = block.minY + 6 + CGFloat(i) * 20
                if i > 0 {
                    ctx.move(to: CGPoint(x: block.minX, y: y - 3))
                    ctx.addLine(to: CGPoint(x: block.maxX, y: y - 3))
                    ctx.setLineWidth(0.4)
                    ctx.strokePath()
                }
                label(ctx, row, at: CGPoint(x: block.maxX - 6, y: y), size: i == 0 ? 11 : 8.5,
                      bold: i == 0, alignRight: true)
            }
        }
        return scaleLabel(paper)
    }

    private static func label(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat,
                              bold: Bool = false, centered: Bool = false, alignRight: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
        let w = str.size().width
        var origin = p
        if centered { origin.x -= w / 2 }
        if alignRight { origin.x -= w }
        UIGraphicsPushContext(ctx)
        str.draw(at: origin)
        UIGraphicsPopContext()
    }

    private static func arrow(_ ctx: CGContext, tip: CGPoint, dx: CGFloat, dy: CGFloat) {
        let len: CGFloat = 5, half: CGFloat = 1.6
        let back = CGPoint(x: tip.x - dx * len, y: tip.y - dy * len)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: back.x - dy * half, y: back.y + dx * half))
        ctx.addLine(to: CGPoint(x: back.x + dy * half, y: back.y - dx * half))
        ctx.closePath()
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fillPath()
    }

    private static func horizontalDimension(_ ctx: CGContext, x1: CGFloat, x2: CGFloat,
                                            from yRef: CGFloat, at y: CGFloat, text: String) {
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.3)
        for x in [x1, x2] {
            ctx.move(to: CGPoint(x: x, y: yRef + 2)); ctx.addLine(to: CGPoint(x: x, y: y + 3))
        }
        ctx.move(to: CGPoint(x: x1, y: y)); ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
        arrow(ctx, tip: CGPoint(x: x1, y: y), dx: -1, dy: 0)
        arrow(ctx, tip: CGPoint(x: x2, y: y), dx: 1, dy: 0)
        label(ctx, text, at: CGPoint(x: (x1 + x2) / 2, y: y - 12), size: 9, centered: true)
    }

    private static func verticalDimension(_ ctx: CGContext, y1: CGFloat, y2: CGFloat,
                                          from xRef: CGFloat, at x: CGFloat, text: String) {
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.3)
        for y in [y1, y2] {
            ctx.move(to: CGPoint(x: xRef - 2, y: y)); ctx.addLine(to: CGPoint(x: x - 3, y: y))
        }
        ctx.move(to: CGPoint(x: x, y: y1)); ctx.addLine(to: CGPoint(x: x, y: y2))
        ctx.strokePath()
        arrow(ctx, tip: CGPoint(x: x, y: y1), dx: 0, dy: -1)
        arrow(ctx, tip: CGPoint(x: x, y: y2), dx: 0, dy: 1)
        ctx.saveGState()
        ctx.translateBy(x: x - 2, y: (y1 + y2) / 2)
        ctx.rotate(by: -.pi / 2)
        label(ctx, text, at: CGPoint(x: 0, y: -11), size: 9, centered: true)
        ctx.restoreGState()
    }

    // MARK: - DXF (millimeters, views laid out like the PDF)

    static func writeDXF(_ m: DrawingModel, to url: URL) throws {
        let L = m.size.x, W = m.size.y, H = m.size.z
        let gap = max(10, 0.3 * max(L, W, H))
        let offsets: [(View, SIMD2<Double>)] = [
            (front, SIMD2(0, 0)),
            (top, SIMD2(0, H + gap)),
            (right, SIMD2(L + gap, 0))
        ]
        var out = "0\nSECTION\n2\nENTITIES\n"
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, layer: String) {
            out += "0\nLINE\n8\n\(layer)\n10\n\(a.x)\n20\n\(a.y)\n30\n0.0\n11\n\(b.x)\n21\n\(b.y)\n31\n0.0\n"
        }
        func text(_ s: String, _ p: SIMD2<Double>, height: Double) {
            out += "0\nTEXT\n8\nDIM\n10\n\(p.x)\n20\n\(p.y)\n30\n0.0\n40\n\(height)\n1\n\(s)\n"
        }
        for (view, off) in offsets {
            for (a, b) in visibleEdges(m, view: view) {
                line(view.project(m.points[a]) + off, view.project(m.points[b]) + off, layer: "VISIBLE")
            }
        }
        let h = max(1.5, 0.04 * max(L, H))
        let dy = -gap * 0.35
        line(SIMD2(0, dy), SIMD2(L, dy), layer: "DIM")
        text("L=\(mmText(L))", SIMD2(L / 2 - 3 * h, dy - 1.5 * h), height: h)
        let dx = -gap * 0.35
        line(SIMD2(dx, 0), SIMD2(dx, H), layer: "DIM")
        text("H=\(mmText(H))", SIMD2(dx - 6 * h, H / 2), height: h)
        line(SIMD2(dx, H + gap), SIMD2(dx, H + gap + W), layer: "DIM")
        text("W=\(mmText(W))", SIMD2(dx - 6 * h, H + gap + W / 2), height: h)
        out += "0\nENDSEC\n0\nEOF\n"
        try out.write(to: url, atomically: true, encoding: .ascii)
    }
}
