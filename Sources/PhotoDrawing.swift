import UIKit
import simd

/// Drawing of a flat part measured from a photo: outline, holes, ordinate dimensions and a hole table.
enum PhotoDrawing {

    private static let ptPerMM = 72.0 / 25.4
    private static let niceScales: [Double] = [10, 5, 4, 2, 1, 0.5, 0.4, 0.25, 0.2, 0.1, 0.05]

    static func holeSizeText(_ hole: PhotoPart.Hole) -> String {
        if let d = hole.diameter { return "Ø" + DrawingGenerator.mmText(d) }
        return DrawingGenerator.mmText(hole.width) + "×" + DrawingGenerator.mmText(hole.length)
    }

    /// Positions to dimension along one axis: datum 0, hole centers, outline corners, full length.
    /// Values closer than 0.5 mm are merged; corners are dropped first when there are too many.
    static func ordinates(holes: [Double], corners: [Double], length: Double, maxCount: Int = 24) -> [Double] {
        var values = [0, length] + holes
        for c in corners where values.count < maxCount { values.append(c) }
        values.sort()
        var out: [Double] = []
        for v in values where out.last.map({ v - $0 >= 0.5 }) ?? true { out.append(v) }
        return out
    }

    static func renderPDF(_ part: PhotoPart, title: String, date: Date, thickness: Double?, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)
        let area = CGRect(x: 40, y: 40, width: 520, height: 430)
        let L = part.size.x, W = part.size.y
        let fit = min((Double(area.width) - 120) / max(L, 1), (Double(area.height) - 130) / max(W, 1)) / ptPerMM
        let paper = niceScales.first { $0 <= fit } ?? niceScales.last!
        let s = CGFloat(paper * ptPerMM)
        let ox = area.midX - CGFloat(L) * s / 2 + 25
        let oy = area.midY + CGFloat(W) * s / 2 - 10
        func P(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: ox + CGFloat(p.x) * s, y: oy - CGFloat(p.y) * s) }
        let left = ox, right = ox + CGFloat(L) * s, bottom = oy, top = oy - CGFloat(W) * s

        let xs = ordinates(holes: part.holes.map(\.center.x), corners: part.corners.map(\.x), length: L)
        let ys = ordinates(holes: part.holes.map(\.center.y), corners: part.corners.map(\.y), length: W)

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            let ctx = context.cgContext
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(page.insetBy(dx: 15, dy: 15))

            // Part with its holes
            let body = CGMutablePath()
            if let f = part.outline.first {
                body.move(to: P(f))
                for p in part.outline.dropFirst() { body.addLine(to: P(p)) }
                body.closeSubpath()
            }
            for hole in part.holes {
                if let d = hole.diameter {
                    let r = CGFloat(d / 2) * s
                    let c = P(hole.center)
                    body.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                } else if let f = hole.outline.first {
                    body.move(to: P(f))
                    for p in hole.outline.dropFirst() { body.addLine(to: P(p)) }
                    body.closeSubpath()
                }
            }
            ctx.addPath(body)
            ctx.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.addPath(body)
            ctx.setLineWidth(0.9)
            ctx.strokePath()

            // Center marks and hole numbers
            ctx.setLineWidth(0.25)
            for (i, hole) in part.holes.enumerated() {
                let c = P(hole.center)
                let r = CGFloat(max(hole.width, hole.length) / 2) * s + 3
                ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
                ctx.strokePath()
                text(ctx, "\(i + 1)", at: CGPoint(x: c.x + r * 0.75, y: c.y - r * 0.75 - 9), size: 7.5, bold: true,
                     color: dimColor)
            }

            // Ordinate dimensions along x (below the part)
            ctx.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
            ctx.setLineWidth(0.2)
            var lastX = -CGFloat.infinity
            for v in xs {
                let x = left + CGFloat(v) * s
                let lx = max(x, lastX + 9)
                lastX = lx
                let featureY = featurePoint(part, alongX: v, s: s, P: P)?.y ?? bottom
                ctx.move(to: CGPoint(x: x, y: featureY + 2))
                ctx.addLine(to: CGPoint(x: x, y: bottom + 6))
                ctx.addLine(to: CGPoint(x: lx, y: bottom + 14))
                ctx.addLine(to: CGPoint(x: lx, y: bottom + 18))
                ctx.strokePath()
                verticalText(ctx, DrawingGenerator.mmText(v), x: lx, startY: bottom + 20)
            }
            // Ordinate dimensions along y (left of the part)
            var lastY = CGFloat.infinity
            for v in ys {
                let y = bottom - CGFloat(v) * s
                let ly = min(y, lastY - 10)
                lastY = ly
                let featureX = featurePoint(part, alongY: v, s: s, P: P)?.x ?? left
                ctx.move(to: CGPoint(x: featureX - 2, y: y))
                ctx.addLine(to: CGPoint(x: left - 6, y: y))
                ctx.addLine(to: CGPoint(x: left - 14, y: ly))
                ctx.addLine(to: CGPoint(x: left - 18, y: ly))
                ctx.strokePath()
                text(ctx, DrawingGenerator.mmText(v), at: CGPoint(x: left - 20, y: ly - 5), size: 7.5, alignRight: true)
            }

            // Overall length above, overall width on the right
            dimension(ctx, from: CGPoint(x: left, y: top - 16), to: CGPoint(x: right, y: top - 16),
                      text: DrawingGenerator.mmText(L), extFrom: [CGPoint(x: left, y: top), CGPoint(x: right, y: top)])
            dimension(ctx, from: CGPoint(x: right + 16, y: bottom), to: CGPoint(x: right + 16, y: top),
                      text: DrawingGenerator.mmText(W), extFrom: [CGPoint(x: right, y: bottom), CGPoint(x: right, y: top)])

            // Hole table
            let table = CGRect(x: 575, y: 30, width: 237, height: 450)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(0.8)
            ctx.stroke(table)
            text(ctx, "טבלת חורים (מ\"מ, מהפינה השמאלית התחתונה)", at: CGPoint(x: table.maxX - 6, y: table.minY + 5),
                 size: 8, bold: true, alignRight: true)
            let cols: [CGFloat] = [table.maxX - 10, table.maxX - 50, table.maxX - 105, table.maxX - 160]
            for (j, head) in ["#", "X", "Y", "מידה"].enumerated() {
                text(ctx, head, at: CGPoint(x: cols[j], y: table.minY + 22), size: 8, bold: true, alignRight: true)
            }
            let maxRows = 28
            for (i, hole) in part.holes.prefix(maxRows).enumerated() {
                let y = table.minY + 38 + CGFloat(i) * 14.5
                let row = ["\(i + 1)", DrawingGenerator.mmText(hole.center.x),
                           DrawingGenerator.mmText(hole.center.y), holeSizeText(hole)]
                for (j, cell) in row.enumerated() {
                    text(ctx, cell, at: CGPoint(x: cols[j], y: y), size: 8, alignRight: true)
                }
            }
            if part.holes.isEmpty {
                text(ctx, "לא נמצאו חורים", at: CGPoint(x: table.maxX - 10, y: table.minY + 40), size: 8, alignRight: true)
            } else if part.holes.count > maxRows {
                text(ctx, "ועוד \(part.holes.count - maxRows) חורים (ראה DXF)",
                     at: CGPoint(x: table.maxX - 10, y: table.maxY - 16), size: 8, alignRight: true)
            }

            // Notes
            let notes = CGRect(x: 30, y: 492, width: 470, height: 88)
            ctx.setLineWidth(0.8)
            ctx.stroke(notes)
            let lines = [
                "מקור: תמונה מלמעלה של חלק שטוח על דף A4.",
                "מתאים לחלקים שטוחים. בחלק עבה הצד העליון נראה גדול מעט מהאמת.",
                "מידות קריטיות יש לאמת בקליבר לפני שליחה לספק."
            ]
            for (i, line) in lines.enumerated() {
                text(ctx, line, at: CGPoint(x: notes.maxX - 6, y: notes.minY + 8 + CGFloat(i) * 18), size: 8.5,
                     alignRight: true)
            }

            // Title block
            let block = CGRect(x: 512, y: 492, width: 300, height: 88)
            ctx.stroke(block)
            let df = DateFormatter()
            df.dateFormat = "dd.MM.yyyy"
            var size = "מידות כלליות: \(DrawingGenerator.mmText(L)) × \(DrawingGenerator.mmText(W))"
            if let t = thickness { size += " × \(DrawingGenerator.mmText(t)) (עובי)" }
            let rows = [
                title,
                "תאריך: \(df.string(from: date))    יחידות: מ\"מ    קנה מידה: \(DrawingGenerator.scaleLabel(paper))",
                size,
                "חורים: \(part.holes.count)"
            ]
            for (i, row) in rows.enumerated() {
                let y = block.minY + 6 + CGFloat(i) * 20
                if i > 0 {
                    ctx.move(to: CGPoint(x: block.minX, y: y - 3))
                    ctx.addLine(to: CGPoint(x: block.maxX, y: y - 3))
                    ctx.setLineWidth(0.4)
                    ctx.strokePath()
                }
                text(ctx, row, at: CGPoint(x: block.maxX - 6, y: y), size: i == 0 ? 11 : 8.5, bold: i == 0,
                     alignRight: true)
            }
        }
    }

    /// The lowest outline/hole point at this x (for the extension line start), in paper coordinates.
    private static func featurePoint(_ part: PhotoPart, alongX v: Double, s: CGFloat,
                                     P: (SIMD2<Double>) -> CGPoint) -> CGPoint? {
        if let h = part.holes.first(where: { abs($0.center.x - v) < 0.3 }) { return P(h.center) }
        if let c = part.corners.first(where: { abs($0.x - v) < 0.3 }) { return P(c) }
        return nil
    }

    private static func featurePoint(_ part: PhotoPart, alongY v: Double, s: CGFloat,
                                     P: (SIMD2<Double>) -> CGPoint) -> CGPoint? {
        if let h = part.holes.first(where: { abs($0.center.y - v) < 0.3 }) { return P(h.center) }
        if let c = part.corners.first(where: { abs($0.y - v) < 0.3 }) { return P(c) }
        return nil
    }

    private static let dimColor = UIColor(red: 0.0, green: 0.25, blue: 0.75, alpha: 1)

    private static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, bold: Bool = false,
                             alignRight: Bool = false, color: UIColor = .black) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        var origin = p
        if alignRight { origin.x -= str.size().width }
        UIGraphicsPushContext(ctx)
        str.draw(at: origin)
        UIGraphicsPopContext()
    }

    /// Text turned to read bottom-to-top, its end at `startY` and running downward from there.
    private static func verticalText(_ ctx: CGContext, _ s: String, x: CGFloat, startY: CGFloat) {
        let font = UIFont.systemFont(ofSize: 7.5)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: UIColor.black])
        let size = str.size()
        ctx.saveGState()
        ctx.translateBy(x: x, y: startY + size.width)
        ctx.rotate(by: -.pi / 2)
        UIGraphicsPushContext(ctx)
        str.draw(at: CGPoint(x: 0, y: -size.height / 2))
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    private static func dimension(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, text label: String,
                                  extFrom: [CGPoint]) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.3)
        for (e, d) in zip(extFrom, [a, b]) {
            ctx.move(to: e); ctx.addLine(to: d)
        }
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.strokePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 1)
        let ux = dx / len, uy = dy / len
        for (tip, sx, sy) in [(a, -ux, -uy), (b, ux, uy)] {
            let back = CGPoint(x: tip.x - sx * 5, y: tip.y - sy * 5)
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: back.x - sy * 1.6, y: back.y + sx * 1.6))
            ctx.addLine(to: CGPoint(x: back.x + sy * 1.6, y: back.y - sx * 1.6))
            ctx.closePath()
            ctx.fillPath()
        }
        let font = UIFont.boldSystemFont(ofSize: 9)
        let str = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor.black])
        let size = str.size()
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if abs(dx) >= abs(dy) {
            UIGraphicsPushContext(ctx)
            str.draw(at: CGPoint(x: mid.x - size.width / 2, y: mid.y - size.height - 1))
            UIGraphicsPopContext()
        } else {
            ctx.translateBy(x: mid.x + 2, y: mid.y + size.width / 2)
            ctx.rotate(by: -.pi / 2)
            UIGraphicsPushContext(ctx)
            str.draw(at: CGPoint(x: 0, y: -size.height - 1 + size.height + 2))
            UIGraphicsPopContext()
        }
        ctx.restoreGState()
    }

    // MARK: - DXF (millimeters)

    static func writeDXF(_ part: PhotoPart, to url: URL) throws {
        var out = "0\nSECTION\n2\nENTITIES\n"
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, layer: String) {
            out += "0\nLINE\n8\n\(layer)\n10\n\(a.x)\n20\n\(a.y)\n30\n0.0\n11\n\(b.x)\n21\n\(b.y)\n31\n0.0\n"
        }
        func loop(_ pts: [SIMD2<Double>], layer: String) {
            guard pts.count >= 2 else { return }
            for i in 0..<pts.count { line(pts[i], pts[(i + 1) % pts.count], layer: layer) }
        }
        func text(_ s: String, _ p: SIMD2<Double>, height: Double) {
            out += "0\nTEXT\n8\nDIM\n10\n\(p.x)\n20\n\(p.y)\n30\n0.0\n40\n\(height)\n1\n\(s)\n"
        }
        loop(part.outline, layer: "OUTLINE")
        let h = max(1.5, 0.02 * max(part.size.x, part.size.y))
        for (i, hole) in part.holes.enumerated() {
            if let d = hole.diameter {
                out += "0\nCIRCLE\n8\nHOLES\n10\n\(hole.center.x)\n20\n\(hole.center.y)\n30\n0.0\n40\n\(d / 2)\n"
            } else {
                loop(hole.outline, layer: "HOLES")
            }
            let size = hole.diameter.map { "D" + DrawingGenerator.mmText($0) }
                ?? DrawingGenerator.mmText(hole.width) + "x" + DrawingGenerator.mmText(hole.length)
            text("\(i + 1): X\(DrawingGenerator.mmText(hole.center.x)) Y\(DrawingGenerator.mmText(hole.center.y)) \(size)",
                 hole.center + SIMD2(max(hole.width, hole.length) / 2 + 1, 1), height: h * 0.6)
        }
        text("L=\(DrawingGenerator.mmText(part.size.x)) W=\(DrawingGenerator.mmText(part.size.y))",
             SIMD2(0, -3 * h), height: h)
        out += "0\nENDSEC\n0\nEOF\n"
        try out.write(to: url, atomically: true, encoding: .ascii)
    }
}
