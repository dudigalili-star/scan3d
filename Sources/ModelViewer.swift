import SwiftUI
import SceneKit
import simd

/// Holds the tap-to-measure state for the 3D viewer.
final class MeasureController: ObservableObject {
    @Published private(set) var distanceMeters: Double?
    @Published var measuring = true

    weak var view: SCNView?
    let markers = SCNNode()
    var markerRadius: CGFloat = 0.001
    private var points: [SCNVector3] = []

    func clear() {
        points.removeAll()
        markers.childNodes.forEach { $0.removeFromParentNode() }
        distanceMeters = nil
    }

    func handleTap(at location: CGPoint) {
        guard measuring, let view else { return }
        let hits = view.hitTest(location, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        guard let hit = hits.first(where: { $0.node.name != "marker" }) else { return }
        if points.count >= 2 { clear() }
        points.append(hit.worldCoordinates)
        addSphere(at: hit.worldCoordinates)
        if points.count == 2 {
            let a = SIMD3<Float>(points[0]), b = SIMD3<Float>(points[1])
            distanceMeters = Double(simd_distance(a, b))
            addLine(from: points[0], to: points[1])
        }
    }

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
        if let scene = try? SCNScene(url: url, options: nil) {
            view.scene = scene
            let radius = scene.rootNode.boundingSphere.radius
            controller.markerRadius = CGFloat(max(radius * 0.012, 0.0004))
            scene.rootNode.addChildNode(controller.markers)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        controller.view = view
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
    }
}
