import UIKit
import SceneKit
import Metal

/// Renders a small preview image of a scan's model, cached next to the scan.
enum Thumbnailer {
    static func image(for scan: ScanItem) -> UIImage? {
        if let cached = UIImage(contentsOfFile: scan.thumbnailURL.path) { return cached }
        guard scan.hasModel, let scene = try? SCNScene(url: scan.modelURL, options: nil) else { return nil }

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true

        let (center, radius) = scene.rootNode.boundingSphere
        let r = max(radius, 0.001)
        let camera = SCNCamera()
        camera.zNear = Double(r) * 0.01
        camera.zFar = Double(r) * 100
        camera.fieldOfView = 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x + r * 2.0, center.y + r * 1.6, center.z + r * 2.0)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        renderer.pointOfView = cameraNode
        scene.background.contents = UIColor(white: 0.13, alpha: 1)

        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 480),
                                      antialiasingMode: .multisampling4X)
        try? image.pngData()?.write(to: scan.thumbnailURL)
        return image
    }
}
