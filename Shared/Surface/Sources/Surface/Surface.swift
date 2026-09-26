import CoreGraphics
import Foundation

/// What a person does to a surface, in the surface's points.
public enum SurfaceInput: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case move, down, drag, up }
    public enum Key: String, Codable, Sendable {
        case enter, tab, escape, backspace, space, left, right, up, down
    }
    case pointer(Phase, x: Double, y: Double, clickCount: Int = 1)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case key(Key)
    case text(String)
}

/// Where a surface sits in a viewer that shows all of it, keeping its shape.
public enum SurfaceGeometry {
    public static func fitted(_ surface: CGSize, in view: CGSize) -> CGRect {
        guard surface.width > 0, surface.height > 0 else { return .zero }
        let scale = min(view.width / surface.width, view.height / surface.height)
        let size = CGSize(width: surface.width * scale, height: surface.height * scale)
        return CGRect(origin: CGPoint(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2), size: size)
    }

    /// The surface point under `point` of a viewer with a top-left origin. Nil outside the surface.
    public static func surfacePoint(_ point: CGPoint, in view: CGSize, surface: CGSize) -> CGPoint? {
        let frame = fitted(surface, in: view)
        guard frame.width > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) * surface.width / frame.width,
                       y: (point.y - frame.minY) * surface.height / frame.height)
    }
}
