import SpriteKit
import SwiftUI

struct Noodlet: View {
    private let scene: OrbitScene = {
        let scene = OrbitScene(size: CGSize(width: 900, height: 620))
        scene.scaleMode = .resizeFill
        return scene
    }()
    var body: some View { SpriteView(scene: scene).ignoresSafeArea() }
}
final class OrbitScene: SKScene {
    private var stars: [SKShapeNode] = []
    private var last: TimeInterval = 0
    override func didMove(to view: SKView) {
        backgroundColor = NSColor(red: 0.045, green: 0.05, blue: 0.11, alpha: 1)
        let title = SKLabelNode(fontNamed: "AvenirNext-Regular")
        title.text = "ORBITAL PLAYGROUND"
        title.fontSize = 15
        title.fontColor = NSColor.white.withAlphaComponent(0.6)
        title.position = CGPoint(x: size.width / 2, y: size.height - 55)
        addChild(title)
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Regular")
        subtitle.text = "A little universe. Click to add a star."
        subtitle.fontSize = 12
        subtitle.fontColor = NSColor.white.withAlphaComponent(0.4)
        subtitle.position = CGPoint(x: size.width / 2, y: 35)
        addChild(subtitle)
        for i in 0..<24 {
            addStar(
                CGPoint(
                    x: size.width / 2 + cos(Double(i)) * Double(70 + i * 8),
                    y: size.height / 2 + sin(Double(i)) * Double(70 + i * 8)))
        }
        print("SpriteKit scene ready: \(stars.count) stars")
    }
    private func addStar(_ point: CGPoint) {
        let star = SKShapeNode(circleOfRadius: CGFloat.random(in: 2...7))
        star.fillColor = NSColor(
            calibratedHue: CGFloat.random(in: 0.55...0.8), saturation: 0.35, brightness: 1, alpha: 1
        )
        star.strokeColor = .clear
        star.glowWidth = 5
        star.position = point
        addChild(star)
        stars.append(star)
    }
    override func mouseDown(with event: NSEvent) {
        addStar(event.location(in: self))
        print("Stars: \(stars.count)")
    }
    override func update(_ currentTime: TimeInterval) {
        let dt = last == 0 ? 0 : min(currentTime - last, 0.05)
        last = currentTime
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for (i, star) in stars.enumerated() {
            let dx = star.position.x - center.x
            let dy = star.position.y - center.y
            let angle = dt * (0.15 + Double(i % 5) * 0.04)
            star.position = CGPoint(
                x: center.x + dx * cos(angle) - dy * sin(angle),
                y: center.y + dx * sin(angle) + dy * cos(angle))
        }
    }
}
