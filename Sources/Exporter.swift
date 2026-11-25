import Foundation
import SceneKit
import ModelIO
import simd

struct MeshData {
    var positions: [SIMD3<Float>] = []   // meters, world space
    var indices: [UInt32] = []           // triangles
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case stl, obj, glb
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stl: return "STL (מ\"מ)"
        case .obj: return "OBJ (מ\"מ)"
        case .glb: return "GLB"
        }
    }
}

enum ExportError: LocalizedError {
    case noGeometry
    var errorDescription: String? { "לא נמצאה גאומטריה במודל" }
}

enum Exporter {

    // MARK: Loading

    static func loadMesh(from url: URL) throws -> MeshData {
        if let mesh = loadWithModelIO(url), !mesh.indices.isEmpty { return mesh }
        return try loadWithSceneKit(url)
    }

    /// Reads triangles straight from the USDZ with ModelIO.
    static func loadWithModelIO(_ url: URL) -> MeshData? {
        let asset = MDLAsset(url: url)
        guard let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh], !meshes.isEmpty else { return nil }
        var out = MeshData()
        for mesh in meshes {
            guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let base = UInt32(out.positions.count)
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let start = attr.dataStart
            let stride = attr.stride
            for i in 0..<mesh.vertexCount {
                let o = i * stride
                let p = SIMD3<Float>(start.loadUnaligned(fromByteOffset: o, as: Float.self),
                                     start.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                     start.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                let w = world * SIMD4<Float>(p, 1)
                out.positions.append(SIMD3(w.x, w.y, w.z))
            }
            guard let submeshes = mesh.submeshes as? [MDLSubmesh] else { continue }
            for sub in submeshes where sub.geometryType == .triangles {
                let buffer = sub.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                let count = sub.indexCount
                for i in 0..<count {
                    let v = map.bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    out.indices.append(base + v)
                }
            }
        }
        return out.positions.isEmpty ? nil : out
    }

    static func loadWithSceneKit(_ url: URL) throws -> MeshData {
        let scene = try SCNScene(url: url, options: nil)
        var mesh = MeshData()
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first else { return }
            let base = UInt32(mesh.positions.count)
            let world = node.simdWorldTransform
            let count = source.vectorCount
            let stride = source.dataStride
            let offset = source.dataOffset
            let bytesPerComponent = source.bytesPerComponent
            source.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    let o = offset + i * stride
                    let p: SIMD3<Float>
                    if bytesPerComponent == 8 {
                        p = SIMD3(Float(raw.loadUnaligned(fromByteOffset: o, as: Double.self)),
                                  Float(raw.loadUnaligned(fromByteOffset: o + 8, as: Double.self)),
                                  Float(raw.loadUnaligned(fromByteOffset: o + 16, as: Double.self)))
                    } else {
                        p = SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                    }
                    let w = world * SIMD4<Float>(p, 1)
                    mesh.positions.append(SIMD3(w.x, w.y, w.z))
                }
            }
            for element in geometry.elements {
                let bytesPerIndex = element.bytesPerIndex
                element.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    func index(_ k: Int) -> UInt32 {
                        let o = k * bytesPerIndex
                        switch bytesPerIndex {
                        case 1: return UInt32(raw.load(fromByteOffset: o, as: UInt8.self))
                        case 2: return UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                        default: return raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                        }
                    }
                    let available = raw.count / max(bytesPerIndex, 1)
                    switch element.primitiveType {
                    case .triangles:
                        let n = min(element.primitiveCount * 3, available)
                        for k in 0..<n { mesh.indices.append(base + index(k)) }
                    case .triangleStrip:
                        let n = min(element.primitiveCount + 2, available)
                        if n >= 3 {
                            for k in 0..<(n - 2) {
                                let a = index(k), b = index(k + 1), c = index(k + 2)
                                if k % 2 == 0 { mesh.indices += [base + a, base + b, base + c] }
                                else { mesh.indices += [base + b, base + a, base + c] }
                            }
                        }
                    case .polygon:
                        // Layout: one vertex count per polygon, then all the polygons' indices.
                        let polygons = element.primitiveCount
                        var cursor = polygons
                        for poly in 0..<polygons {
                            let corners = Int(index(poly))
                            guard corners >= 3, cursor + corners <= available else { cursor += corners; continue }
                            for k in 1..<(corners - 1) {
                                mesh.indices += [base + index(cursor), base + index(cursor + k), base + index(cursor + k + 1)]
                            }
                            cursor += corners
                        }
                    default:
                        break
                    }
                }
            }
        }
        if mesh.positions.isEmpty || mesh.indices.isEmpty { throw ExportError.noGeometry }
        return mesh
    }

    // MARK: Overall size (oriented bounding box via PCA)

    /// Returns the three side lengths of the oriented bounding box in meters, largest first.
    static func orientedSize(_ points: [SIMD3<Float>]) -> SIMD3<Double> {
        guard points.count > 3 else { return .zero }
        var mean = SIMD3<Double>.zero
        for p in points { mean += SIMD3<Double>(p) }
        mean /= Double(points.count)
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in points {
            let d = SIMD3<Double>(p) - mean
            for i in 0..<3 { for j in 0..<3 { cov[i][j] += d[i] * d[j] } }
        }
        let axes = jacobiEigenvectors(cov)
        var lo = [Double](repeating: .infinity, count: 3)
        var hi = [Double](repeating: -.infinity, count: 3)
        for p in points {
            let d = SIMD3<Double>(p) - mean
            for k in 0..<3 {
                let proj = d.x * axes[0][k] + d.y * axes[1][k] + d.z * axes[2][k]
                lo[k] = min(lo[k], proj)
                hi[k] = max(hi[k], proj)
            }
        }
        let sizes = (0..<3).map { hi[$0] - lo[$0] }.sorted(by: >)
        return SIMD3(sizes[0], sizes[1], sizes[2])
    }

    /// Eigenvectors (as columns) of a symmetric 3x3 matrix, by cyclic Jacobi rotations.
    static func jacobiEigenvectors(_ input: [[Double]]) -> [[Double]] {
        var a = input
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<60 {
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { largest = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > largest { largest = abs(a[1][2]); p = 1; q = 2 }
            if largest < 1e-15 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        return v
    }

    // MARK: Writing

    /// `scale` is the caliper correction factor (1.0 = LiDAR scale as captured).
    static func export(_ mesh: MeshData, format: ExportFormat, scale: Double, to url: URL) throws {
        switch format {
        case .stl: try writeSTL(mesh, factor: Float(scale * 1000), to: url)
        case .obj: try writeOBJ(mesh, factor: Float(scale * 1000), to: url)
        case .glb: try writeGLB(mesh, factor: Float(scale), to: url)
        }
    }

    private static func append<T>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    static func writeSTL(_ mesh: MeshData, factor: Float, to url: URL) throws {
        let triangles = mesh.indices.count / 3
        var data = Data(count: 80)
        data.reserveCapacity(84 + triangles * 50)
        append(&data, UInt32(triangles))
        for t in 0..<triangles {
            let a = mesh.positions[Int(mesh.indices[3 * t])] * factor
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])] * factor
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])] * factor
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : .zero
            for v in [n, a, b, c] {
                append(&data, v.x); append(&data, v.y); append(&data, v.z)
            }
            append(&data, UInt16(0))
        }
        try data.write(to: url)
    }

    static func writeOBJ(_ mesh: MeshData, factor: Float, to url: URL) throws {
        var text = "# Scan3D export, units: millimeters\n"
        text.reserveCapacity(mesh.positions.count * 36 + mesh.indices.count * 8)
        for p in mesh.positions {
            let s = p * factor
            text += "v \(s.x) \(s.y) \(s.z)\n"
        }
        var i = 0
        while i + 2 < mesh.indices.count {
            text += "f \(mesh.indices[i] + 1) \(mesh.indices[i + 1] + 1) \(mesh.indices[i + 2] + 1)\n"
            i += 3
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeGLB(_ mesh: MeshData, factor: Float, to url: URL) throws {
        var bin = Data()
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            let s = p * factor
            lo = simd_min(lo, s); hi = simd_max(hi, s)
            append(&bin, s.x); append(&bin, s.y); append(&bin, s.z)
        }
        let positionBytes = bin.count
        for i in mesh.indices { append(&bin, i) }
        let indexBytes = bin.count - positionBytes
        while bin.count % 4 != 0 { bin.append(0) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Scan3D"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionBytes, "target": 34962],
                ["buffer": 0, "byteOffset": positionBytes, "byteLength": indexBytes, "target": 34963]
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": mesh.positions.count, "type": "VEC3",
                 "min": [Double(lo.x), Double(lo.y), Double(lo.z)],
                 "max": [Double(hi.x), Double(hi.y), Double(hi.z)]],
                ["bufferView": 1, "componentType": 5125, "count": mesh.indices.count, "type": "SCALAR"]
            ]
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var out = Data()
        append(&out, UInt32(0x4654_6C67))                          // "glTF"
        append(&out, UInt32(2))
        append(&out, UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        append(&out, UInt32(jsonData.count)); append(&out, UInt32(0x4E4F_534A)) // JSON
        out.append(jsonData)
        append(&out, UInt32(bin.count)); append(&out, UInt32(0x004E_4942))      // BIN
        out.append(bin)
        try out.write(to: url)
    }
}
