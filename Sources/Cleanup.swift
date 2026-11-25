import Foundation
import simd

/// Removes the parts of a scan the user marked as not relevant (painted spots and everything below a cut height).
enum Cleanup {

    /// Lowest Y of the mesh (Object Capture models are Y-up).
    static func baseY(_ mesh: MeshData) -> Float {
        mesh.positions.map(\.y).min() ?? 0
    }

    /// Per-vertex flag: true when the vertex is inside a painted spot or below the cut.
    static func removedVertices(_ mesh: MeshData, erase: [EraseMark], cutHeight: Float?) -> [Bool] {
        var removed = [Bool](repeating: false, count: mesh.positions.count)
        if let cut = cutHeight, cut > 0 {
            let limit = baseY(mesh) + cut
            for (i, p) in mesh.positions.enumerated() where p.y < limit { removed[i] = true }
        }
        for mark in erase { paint(mark, mesh: mesh, into: &removed) }
        return removed
    }

    /// Adds one painted spot to an existing per-vertex mask.
    static func paint(_ mark: EraseMark, mesh: MeshData, into removed: inout [Bool]) {
        let c = mark.center, r2 = mark.r * mark.r
        for (i, p) in mesh.positions.enumerated() where !removed[i] && simd_distance_squared(p, c) <= r2 {
            removed[i] = true
        }
    }

    /// Splits the triangles into kept and removed index lists.
    static func split(_ mesh: MeshData, removed: [Bool]) -> (kept: [UInt32], removed: [UInt32]) {
        var kept: [UInt32] = [], gone: [UInt32] = []
        kept.reserveCapacity(mesh.indices.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            if removed[Int(a)] || removed[Int(b)] || removed[Int(c)] {
                gone.append(contentsOf: [a, b, c])
            } else {
                kept.append(contentsOf: [a, b, c])
            }
            i += 3
        }
        return (kept, gone)
    }

    /// The mesh without the marked parts and without small loose pieces left behind.
    static func apply(_ mesh: MeshData, meta: ScanMeta) -> MeshData {
        guard meta.hasCleanup else { return mesh }
        let removed = removedVertices(mesh, erase: meta.erase ?? [], cutHeight: meta.cutHeight)
        let kept = split(mesh, removed: removed).kept
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity(kept.count / 3)
        var i = 0
        while i + 2 < kept.count {
            tris.append(SIMD3(Int32(kept[i]), Int32(kept[i + 1]), Int32(kept[i + 2])))
            i += 3
        }
        tris = DrawingGenerator.largeComponents(tris, vertexCount: mesh.positions.count, minShare: 0.02)

        var remap = [Int32](repeating: -1, count: mesh.positions.count)
        var out = MeshData()
        for t in tris {
            for v in [t.x, t.y, t.z] {
                if remap[Int(v)] < 0 {
                    remap[Int(v)] = Int32(out.positions.count)
                    out.positions.append(mesh.positions[Int(v)])
                }
                out.indices.append(UInt32(remap[Int(v)]))
            }
        }
        return out
    }

    /// Smooth per-vertex normals (for showing the mesh without its texture).
    static func vertexNormals(_ mesh: MeshData) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            let n = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            i += 3
        }
        return normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }
}
