import SwiftUI
import SceneKit
import simd

enum ViewerMode: Hashable { case measure, clean }

/// State of the 3D viewer: tap-to-measure, and the cleanup mode where the user paints parts to delete.
final class MeasureController: ObservableObject {
    @Published private(set) var distanceMeters: Double?
    @Published var mode: ViewerMode = .measure { didSet { modeChanged() } }
    /// In cleanup mode: true = a finger drag paints, false = a drag turns the model.
    @Published var painting = false { didSet { gesturesChanged() } }
    @Published private(set) var marks: [EraseMark] = []
    @Published private(set) var cutHeight: Float = 0
    @Published var brushFraction: Float = 0.04

    weak var view: SCNView?
    weak var paintGesture: UIPanGestureRecognizer?
    let markers = SCNNode()
    /// The textured model from the USDZ file.
    let modelNode = SCNNode()
    /// The same mesh without texture, colored by what will be kept (gray) and deleted (red).
    let cleanNode = SCNNode()
    var markerRadius: CGFloat = 0.001

    private var points: [SIMD3<Float>] = []
    private var mesh: MeshData?
    private var removed: [Bool] = []
    private var strokeStarts: [Int] = []
    private var vertexSource: SCNGeometrySource?
    private var normalSource: SCNGeometrySource?
    private(set) var modelRadius: Float = 0.1
    private(set) var modelHeight: Float = 0.1

    var measuredPoints: (SIMD3<Float>, SIMD3<Float>)? {
        points.count == 2 ? (points[0], points[1]) : nil
    }

    var hasCleanup: Bool { !marks.isEmpty || cutHeight > 0 }

    // MARK: Setup

    func setMesh(_ mesh: MeshData, meta: ScanMeta) {
        self.mesh = mesh
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        modelRadius = max(simd_length(hi - lo) / 2, 0.005)
        modelHeight = max(hi.y - lo.y, 0.001)
        vertexSource = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        normalSource = SCNGeometrySource(normals: Cleanup.vertexNormals(mesh).map { SCNVector3($0.x, $0.y, $0.z) })
        marks = meta.erase ?? []
        strokeStarts = marks.isEmpty ? [] : [0]
        cutHeight = meta.cutHeight ?? 0
        rebuildMask()
    }

    // MARK: Measuring

    func clear() {
        points.removeAll()
        markers.childNodes.forEach { $0.removeFromParentNode() }
        distanceMeters = nil
    }

    func handleTap(at location: CGPoint) {
        if mode == .clean {
            strokeStarts.append(marks.count)
            paint(at: location)
            return
        }
        guard let hit = hitPoint(at: location) else { return }
        if points.count >= 2 { clear() }
        points.append(hit)
        addSphere(at: SCNVector3(hit.x, hit.y, hit.z))
        if points.count == 2 {
            distanceMeters = Double(simd_distance(points[0], points[1]))
            addLine(from: SCNVector3(points[0].x, points[0].y, points[0].z),
                    to: SCNVector3(points[1].x, points[1].y, points[1].z))
        }
    }

    private func hitPoint(at location: CGPoint) -> SIMD3<Float>? {
        guard let view else { return nil }
        let hits = view.hitTest(location, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        guard let hit = hits.first(where: { $0.node.name != "marker" }) else { return nil }
        let w = hit.worldCoordinates
        return SIMD3(w.x, w.y, w.z)
    }

    // MARK: Cleanup

    func beginStroke() { strokeStarts.append(marks.count) }

    func paint(at location: CGPoint) {
        guard mesh != nil, let p = hitPoint(at: location) else { return }
        let r = brushFraction * modelRadius
        if let last = marks.last, strokeStarts.last ?? 0 < marks.count,
           simd_distance(last.center, p) < r * 0.4 { return }
        let mark = EraseMark(x: p.x, y: p.y, z: p.z, r: r)
        marks.append(mark)
        if let mesh { Cleanup.paint(mark, mesh: mesh, into: &removed) }
        refreshGeometry()
    }

    func undoStroke() {
        guard let start = strokeStarts.popLast() else { return }
        marks.removeSubrange(min(start, marks.count)..<marks.count)
        rebuildMask()
    }

    func clearCleanup() {
        marks.removeAll()
        strokeStarts.removeAll()
        cutHeight = 0
        rebuildMask()
    }

    func setCut(_ meters: Float) {
        cutHeight = max(0, meters)
        rebuildMask()
    }

    private func rebuildMask() {
        guard let mesh else { return }
        removed = Cleanup.removedVertices(mesh, erase: marks, cutHeight: cutHeight)
        refreshGeometry()
    }

    private func refreshGeometry() {
        guard let mesh, let vertexSource, let normalSource else { return }
        let parts = Cleanup.split(mesh, removed: removed)
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        if !parts.kept.isEmpty {
            elements.append(SCNGeometryElement(indices: parts.kept, primitiveType: .triangles))
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            m.lightingModel = .blinn
            m.isDoubleSided = true
            materials.append(m)
        }
        if mode == .clean && !parts.removed.isEmpty {
            elements.append(SCNGeometryElement(indices: parts.removed, primitiveType: .triangles))
            let m = SCNMaterial()
            m.diffuse.contents = UIColor.systemRed
            m.lightingModel = .blinn
            m.isDoubleSided = true
            materials.append(m)
        }
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
        geometry.materials = materials
        cleanNode.geometry = geometry
        updateVisibility()
    }

    private func modeChanged() {
        if mode == .clean { clear() } else { painting = false }
        refreshGeometry()
        updateVisibility()
        gesturesChanged()
    }

    private func updateVisibility() {
        let showClean = mesh != nil && (mode == .clean || hasCleanup)
        modelNode.isHidden = showClean
        cleanNode.isHidden = !showClean
    }

    func gesturesChanged() {
        let paint = mode == .clean && painting
        view?.allowsCameraControl = !paint
        paintGesture?.isEnabled = paint
    }

    // MARK: Markers

    private func addSphere(at position: SCNVector3) {
        let sphere = SCNSphere(radius: markerRadius)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemRed
        sphere.firstMaterial?.lightingModel = .constant
        sphere.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: sphere)
        node.name = "marker"
        node.position = position
        node.renderingOrder = 10
        markers.addChildNode(node)
    }

    private func addLine(from a: SCNVector3, to b: SCNVector3) {
        let source = SCNGeometrySource(vertices: [a, b])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemRed
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: geometry)
        node.name = "marker"
        node.renderingOrder = 10
        markers.addChildNode(node)
    }
}

struct ModelSceneView: UIViewRepresentable {
    let url: URL
    @ObservedObject var controller: MeasureController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .secondarySystemBackground
        let scene = (try? SCNScene(url: url, options: nil)) ?? SCNScene()
        view.scene = scene
        let radius = scene.rootNode.boundingSphere.radius
        controller.markerRadius = CGFloat(max(radius * 0.012, 0.0004))
        controller.modelNode.childNodes.forEach { $0.removeFromParentNode() }
        for child in scene.rootNode.childNodes {
            controller.modelNode.addChildNode(child)
        }
        scene.rootNode.addChildNode(controller.modelNode)
        scene.rootNode.addChildNode(controller.cleanNode)
        scene.rootNode.addChildNode(controller.markers)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        controller.view = view
        controller.paintGesture = pan
        controller.gesturesChanged()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject {
        let controller: MeasureController
        init(controller: MeasureController) { self.controller = controller }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            controller.handleTap(at: gesture.location(in: gesture.view))
        }

        @objc func didPan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { controller.beginStroke() }
            if gesture.state == .began || gesture.state == .changed {
                controller.paint(at: gesture.location(in: gesture.view))
            }
        }
    }
}
